/*
 * 社区文章详情 —— 移植 PR #7378 app/community/[id].tsx：
 *   文章卡（类型/问答状态、标题、作者、封面、正文、标签、浏览/点赞/评论统计）+ 全部评论列表
 *   + 底部互动条（评论输入、发送、点赞、分享）。
 * 正文取 body_text（纯文本，可选中复制）——与 7378 同口径；body_html 不在这里渲染。
 * 键盘避让：官方 KeyboardAvoidMode.NONE + avoidAreaChange 自让底部（与聊天页同一套）。
 */

import { HdsNavDestination, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { window, KeyboardAvoidMode, curves, LengthMetrics, uiMaterial } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import {
  CommunityComment, CommunityArticleDetail, getCommunityArticle, getCommunityComments,
  createCommunityComment, likeCommunityArticle, communityArticleUrl, communityInitials,
  formatCommunityDate, normalizeCommunityText, removeCommunityEmoji
} from '../services/CommunityService';
import { getPlatformAccessToken } from '../services/PlatformSession';
import { PlatformLoginParam } from '../components/CommunityTab';
import { ThemeManager, ThemeSnapshot, ThemeListener } from '../theme/ThemeManager';
import { UiTokens, pxPerVp } from '../theme/UiTokens';
import { PRESS_SCALE, PressLatch, pressEffect, pressTouch } from '../theme/PressFx';

// 底部系统导航区保底值（vp）
const NAV_FALLBACK_INSET: number = 12;
// 底部互动条的渐变模糊：最大半径（fractionStops 末段比例见使用处）
const DOCK_BLUR_RADIUS: number = 40;
// 悬浮互动条本体高度（vp）= 聊天页同一口径（栏体高度 = chatComposerHeight + 1）与离底间距
const DOCK_BAR_H: number = 59;
const DOCK_BOTTOM_MARGIN: number = 12;

@Builder
export function CommunityArticlePageBuilder(_name: string, param: Object) {
  CommunityArticlePage({ params: param })
}

@Component
export struct CommunityArticlePage {
  params: Object = new Object();
  @State detail: CommunityArticleDetail | null = null;
  @State comments: CommunityComment[] = [];
  @State loading: boolean = true;
  @State error: string = '';
  @State commentText: string = '';
  @State submitting: boolean = false;
  @State keyboardInset: number = 0;
  @State navInset: number = NAV_FALLBACK_INSET;
  @State pressed: number = -1;
  @State isDark: boolean = false;
  @State theme: ThemeSnapshot = ThemeManager.get().snapshot();
  private articleId: string = '';
  private stack: NavPathStack | null = null;
  private latch: PressLatch = new PressLatch();
  private themeListener: ThemeListener | null = null;
  private kbWindow: window.Window | null = null;
  private kbListener: ((data: window.AvoidAreaOptions) => void) | null = null;
  private prevKeyboardAvoidMode: KeyboardAvoidMode | null = null;

  aboutToAppear(): void {
    const rec: Record<string, Object> = this.params as Record<string, Object>;
    const id: Object = rec['articleId'];
    this.articleId = typeof id === 'string' ? id as string : '';
    const st: Object = rec['stack'];
    this.stack = (st === undefined || st === null) ? null : st as NavPathStack;
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.isDark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.themeListener = (snap: ThemeSnapshot): void => {
      this.theme = snap;
    };
    ThemeManager.get().subscribe(this.themeListener);
    ThemeManager.get().load(ctx).then((): void => {
      this.theme = ThemeManager.get().snapshot();
    });
    this.setupKeyboard();
    this.load();
  }

  aboutToDisappear(): void {
    if (this.kbWindow !== null && this.kbListener !== null) {
      this.kbWindow.off('avoidAreaChange', this.kbListener);
      this.kbWindow = null;
      this.kbListener = null;
    }
    const kb: KeyboardAvoidMode | null = this.prevKeyboardAvoidMode;
    if (kb !== null) {
      this.getUIContext().setKeyboardAvoidMode(kb);
      this.prevKeyboardAvoidMode = null;
    }
    if (this.themeListener !== null) {
      ThemeManager.get().unsubscribe(this.themeListener);
      this.themeListener = null;
    }
  }

  private setupKeyboard(): void {
    this.prevKeyboardAvoidMode = this.getUIContext().getKeyboardAvoidMode();
    window.getLastWindow(getContext(this)).then((w: window.Window): void => {
      this.kbWindow = w;
      const navPx: number = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR)
        .bottomRect.height;
      this.navInset = navPx > 0 ? navPx / pxPerVp() : NAV_FALLBACK_INSET;
      const cb = (data: window.AvoidAreaOptions): void => {
        if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) {
          const inset: number = data.area.bottomRect.height / pxPerVp();
          this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.68) }, (): void => {
            this.keyboardInset = inset;
          });
        }
      };
      this.kbListener = cb;
      w.on('avoidAreaChange', cb);
    });
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
  }

  private t(res: Resource): string {
    try {
      const host: common.Context = this.getUIContext().getHostContext() as common.Context;
      return host.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  private accent(): ResourceColor {
    return this.isDark ? this.theme.accentDark : this.theme.accent;
  }

  private async load(): Promise<void> {
    if (this.articleId.length === 0) {
      this.loading = false;
      this.error = this.t($r('app.string.community_article_error_copy'));
      return;
    }
    this.loading = true;
    this.error = '';
    try {
      const detail: CommunityArticleDetail = await getCommunityArticle(this.articleId);
      const comments: CommunityComment[] = (await getCommunityComments(this.articleId)).items;
      this.detail = detail;
      this.comments = comments;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private share(): void {
    const detail: CommunityArticleDetail | null = this.detail;
    if (detail === null) {
      return;
    }
    const url: string = communityArticleUrl(detail.article.id);
    try {
      const data: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.TEXT,
        content: `${detail.article.title}\n${url}`,
        title: detail.article.title
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      controller.show(this.getUIContext().getHostContext() as common.UIAbilityContext, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL
      }).catch((): void => {
      });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: url });
    }
  }

  // 未登录：提示后跳 Platform 登录页（对齐 7378 promptPlatformLogin）
  private promptPlatformLogin(): void {
    this.getUIContext().showAlertDialog({
      title: this.t($r('app.string.community_login_required_title')),
      message: this.t($r('app.string.community_login_required_copy')),
      primaryButton: {
        value: this.t($r('app.string.common_cancel')),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: this.t($r('app.string.community_login_action')),
        action: (): void => {
          const stack: NavPathStack | null = this.stack;
          if (stack !== null) {
            const param: PlatformLoginParam = { returnTo: '', stack: stack };
            stack.pushPath({ name: 'platform-login', param: param });
          }
        }
      }
    });
  }

  private async like(): Promise<void> {
    const detail: CommunityArticleDetail | null = this.detail;
    if (detail === null) {
      return;
    }
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const token: string = await getPlatformAccessToken(ctx);
    if (token.length === 0) {
      this.promptPlatformLogin();
      return;
    }
    try {
      const updated = await likeCommunityArticle(ctx, detail.article.id);
      detail.article.liked = updated.liked;
      detail.article.likeCount = updated.likeCount;
      this.detail = detail;
    } catch (e) {
      this.getUIContext().showAlertDialog({
        title: this.t($r('app.string.community_like_failed_title')),
        message: (e as Error).message
      });
    }
  }

  private async submitComment(): Promise<void> {
    const detail: CommunityArticleDetail | null = this.detail;
    if (detail === null || this.commentText.trim().length === 0 || this.submitting) {
      return;
    }
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const token: string = await getPlatformAccessToken(ctx);
    if (token.length === 0) {
      this.promptPlatformLogin();
      return;
    }
    this.submitting = true;
    try {
      const comment: CommunityComment =
        await createCommunityComment(ctx, detail.article.id, this.commentText);
      const next: CommunityComment[] = [comment];
      for (const item of this.comments) {
        next.push(item);
      }
      this.comments = next;
      detail.article.commentCount = detail.article.commentCount + 1;
      this.detail = detail;
      this.commentText = '';
    } catch (e) {
      this.getUIContext().showAlertDialog({
        title: this.t($r('app.string.community_comment_failed')),
        message: (e as Error).message
      });
    } finally {
      this.submitting = false;
    }
  }

  build() {
    HdsNavDestination() {
      Column() {
        if (this.loading) {
          this.stateCenter(false)
        } else if (this.error.length > 0 || this.detail === null) {
          this.stateCenter(true)
        } else {
          // 底部输入条 = ArkUI Tabs 的「悬浮页签栏」（与聊天页 composer 同一机制）：
          // 内容区（标题栏/End 位置 TabBar/弹窗之外）没有可直接上沉浸材质的 API，唯一官方路径就是
          // Tabs(barPosition=End) + barOverlap + barFloatingStyle.systemMaterial（见
          // 《沉浸光感典型场景》底部 Tabs 悬浮示例）。barFloatingStyle 里的交互材质同时给到
          // 按压弹性与手指跟随光；键盘避让沿用 KeyboardAvoidMode.NONE + avoidAreaChange。
          Tabs({ barPosition: BarPosition.End, index: 0 }) {
            TabContent() {
            List() {
              ListItem() {
                this.articleBlock()
              }
            ListItem() {
              Row() {
                Text($r('app.string.community_all_comments'))
                  .fontSize(UiTokens.fsBody)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary_strong'))
                Text(this.detail.article.commentCount.toString())
                  .fontSize(UiTokens.fsCaption)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ left: 6 })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({
                left: UiTokens.pageHMargin, right: UiTokens.pageHMargin, top: 16, bottom: 8
              })
            }
            if (this.comments.length === 0) {
              ListItem() {
                Text($r('app.string.community_no_comments'))
                  .fontSize(UiTokens.fsSecondary)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 24, bottom: 24 })
              }
            }
              ForEach(this.comments, (comment: CommunityComment) => {
                ListItem() {
                  this.commentRow(comment, false)
                }
              }, (comment: CommunityComment) => comment.id)
              // 末项 spacer：让开底部互动条（留白必须落在滚动内容里，容器 padding 会裁掉视口）
              ListItem() {
                Column().width('100%').height(this.dockInset())
              }
            }
            .width('100%')
            .height('100%')
            .scrollBar(BarState.Off)
            // 渐变模糊挂在**滚动内容自身**（官方：linearGradientBlur 按位置逐段给半径）——
            // 评论往上滚到底部互动条之下时被渐隐；fractionStops = [[半径倍率, 位置], …]，
            // Bottom 方向下位置 0 = 顶、1 = 底；此处只在末端起糊（dock 那一段）
            // 起糊位置压到列表末端 ~12%（≈ 悬浮条带自身高度）：正文仍在清晰区，
            // 只有落到条带之下的评论被渐隐 —— 起糊过早会把正文也糊掉
            .linearGradientBlur(DOCK_BLUR_RADIUS, {
              fractionStops: [[0, 0], [0, 0.88], [1, 1]],
              direction: GradientDirection.Bottom
            })

            .width('100%')
            .height('100%')
            }
            .tabBar(this.dockBar())
          }
          .barOverlap(true)
          // 单页不滑动：避免"拖动一半"这种中间态（与聊天页一致）
          .scrollable(false)
          // 栏体高度按聊天页口径：barHeight = chatComposerHeight + 1（栏体 203px、内容区 175px
          // = chatComposerBarInner）——栏体与内容区差 8vp，行高必须按内容区给，否则行被压扁、
          // 组件贴底（表现为"没有垂直居中"）
          .barHeight(UiTokens.chatComposerHeight + 1)
          .barFloatingStyle({
            // 悬浮栏默认按内容自适应宽度（会把输入框压窄）→ 显式给宽度：
            // 344vp + 两侧 16vp = 376vp = 屏幕全宽（1316px @3.5）
            barWidth: { smallBarWidth: 344, mediumBarWidth: 344, largeBarWidth: 344 },
            barSideMargin: UiTokens.pageHMargin,
            // 栏体遮罩默认近黑：按压/拖动时栏体形变会露出遮罩（表现为黑边）→ 置透明
            maskColor: Color.Transparent,
            barBottomMargin: DOCK_BOTTOM_MARGIN,
            systemMaterial: new uiMaterial.ImmersiveMaterial({
              style: uiMaterial.ImmersiveStyle.THIN,
              interactive: true,
              lightEffect: { color: this.accent() }
            })
          })
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.keyboardInset })
      .backgroundColor($r('app.color.page_bg'))
      .alignItems(HorizontalAlign.Start)
    }
    // 内容也扩到安全区外（布局级，与 expandSafeArea 同设时优先）：二级页四边都扩，
    // 否则下端/左右两侧会露出窗口底色（页面底部输入条一带表现为黑带）
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],
      [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM, LayoutSafeAreaEdge.START, LayoutSafeAreaEdge.END])
    .titleBar({
      style: {
        scrollEffectOpts: {
          // enableScrollEffect = false：官方口径「不随内容区滚动动态生效标题栏样式，仅生效 originalStyle」，
          // 且 GRADIENT_BLUR 下「直接生效模糊。此方式适用于列表型非沉浸式场景」。
          // 为什么不用 true：为 true 时样式会在 originalStyle→scrollEffectStyle 之间随滚动**插值**，
          // 上滚过程出现"先变暗、再慢慢回到主题色"的过渡观感（反复被报的"往上滑突然变黑然后慢慢
          // 出现主题色"）；关掉后底色/模糊只有一个状态，结构上不可能再出现滚动时变色。
          // 标题栏随滚动收起（titleMode FREE）与内容穿过时的模糊都不受影响。
          enableScrollEffect: false,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        // blurStrategy 用 ENABLE 而不是 ADAPTIVE：官方口径 ADAPTIVE「根据系统策略调整…只有精美档位
        // 配置能够生效模糊效果」—— 系统策略落在轻柔/流畅档时标题栏模糊整块不生效，内容滚过时就露出
        // 未模糊的暗色内容（观感即"往上滑突然变黑"）；ENABLE 恒生效，观感才稳定。
        blurStrategy: BlurStrategy.ENABLE,
        // maskExtraHeight 必须写在生效态（enableScrollEffect=false 时只生效 originalStyle），
        // 否则退回平台默认外扩（实测比标题栏底边多约 56vp），在工具条下方留下中性灰带。
        originalStyle: {
          backgroundStyle: { blurRadius: 12.0, maskExtraHeight: 0.0, backgroundColor: this.accent() }
        },
        scrollEffectStyle: {
          backgroundStyle: { blurRadius: 12.0, backgroundColor: this.accent() }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        title: { mainTitle: $r('app.string.community_detail_title') }
      },
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: false
    })
    .expandSafeArea([SafeAreaType.SYSTEM],
      [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
  }

  @Builder
  stateCenter(isError: boolean) {
    Column() {
      if (isError) {
        Column() {
          Image($r('app.media.refresh_cw'))
            .width(27).height(27)
            .fillColor(this.accent())
        }
        .width(54)
        .height(54)
        .borderRadius(17)
        .backgroundColor($r('app.color.card_bg'))
        .justifyContent(FlexAlign.Center)
        .margin({ bottom: 12 })
        Text($r('app.string.community_article_error_title'))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary_strong'))
        Text(this.error.length > 0
          ? this.error : this.t($r('app.string.community_article_error_copy')))
          .fontSize(UiTokens.fsSecondary)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
          .lineHeight(19)
          .margin({ top: 6 })
        Text($r('app.string.community_reload'))
          .fontSize(UiTokens.fsSecondary)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .height(44)
          .padding({ left: 24, right: 24 })
          .borderRadius(12)
          .backgroundColor(this.accent())
          .margin({ top: 16 })
          .onClick((): void => {
            this.load();
          })
      } else {
        LoadingProgress()
          .width(28)
          .height(28)
          .color(this.accent())
          .margin({ bottom: 12 })
        Text($r('app.string.community_loading_article'))
          .fontSize(UiTokens.fsSecondary)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: 80, left: 32, right: 32 })
  }

  @Builder
  avatar(name: string, uri: string, official: boolean, size: number) {
    if (uri.length > 0) {
      Image(uri)
        .width(size)
        .height(size)
        .borderRadius(Math.round(size * 0.3))
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.card_bg'))
    } else if (official) {
      Image($r('app.media.qwenpaw_symbol'))
        .width(size)
        .height(size)
        .borderRadius(Math.round(size * 0.3))
        .objectFit(ImageFit.Contain)
        .draggable(false)
        .backgroundColor($r('app.color.card_bg'))
    } else {
      Column() {
        Text(communityInitials(name))
          .fontSize(Math.max(11, Math.round(size * 0.29)))
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
      }
      .width(size)
      .height(size)
      .borderRadius(Math.round(size * 0.3))
      .backgroundColor(this.accent())
      .justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  statLine(icon: Resource, label: string) {
    Row({ space: 5 }) {
      Image(icon)
        .width(14).height(14)
        .fillColor($r('app.color.text_tertiary'))
      Text(label)
        .fontSize(UiTokens.fsChip)
        .fontColor($r('app.color.text_tertiary'))
    }
    .margin({ right: 16 })
  }

  @Builder
  articleBlock() {
    Column() {
      Row({ space: 8 }) {
        Text(this.detail !== null ? this.detail.article.articleTypeLabel : '')
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accent())
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(9)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        if (this.detail !== null && this.detail.article.qaStatus.length > 0) {
          Text(this.detail.article.qaStatus === 'solved'
            ? $r('app.string.community_qa_solved') : $r('app.string.community_qa_open'))
            .fontSize(UiTokens.fsChip)
            .fontColor(this.accent())
        }
      }
      .width('100%')

      Text(this.detail !== null ? normalizeCommunityText(this.detail.article.title) : '')
        .fontSize(25)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary_strong'))
        .lineHeight(34)
        .width('100%')
        .margin({ top: 12 })

      Row() {
        this.avatar(this.detail !== null ? this.detail.article.authorName : '',
          this.detail !== null ? this.detail.article.authorAvatarUrl : '',
          this.detail !== null && this.detail.article.identityBadge !== null &&
            this.detail.article.identityBadge.code === 'official', 38)
        Column() {
          Row({ space: 4 }) {
            Text(this.detail !== null && this.detail.article.authorName.length > 0
              ? this.detail.article.authorName : this.t($r('app.string.community_user')))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary_strong'))
              .maxLines(1)
            if (this.detail !== null && this.detail.article.identityBadge !== null) {
              Image($r('app.media.shield_check'))
                .width(14).height(14)
                .fillColor(this.accent())
            }
          }
          .alignItems(VerticalAlign.Center)
          Text(this.detail !== null
            ? formatCommunityDate(this.detail.article.publishedAt) : '')
            .fontSize(UiTokens.fsChip)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 16 })

      if (this.detail !== null && this.detail.article.coverUrl.length > 0) {
        Image(this.detail.article.coverUrl)
          .width('100%')
          .aspectRatio(16 / 9)
          .objectFit(ImageFit.Cover)
          .borderRadius(15)
          .backgroundColor($r('app.color.card_bg'))
          .margin({ top: 14 })
      }

      // 正文（纯文本、可选中复制；对齐 7378 的 body_text + selectable）
      Text(this.detail !== null ? removeCommunityEmoji(this.detail.bodyText) : '')
        .fontSize(UiTokens.fsBody)
        .fontColor($r('app.color.text_primary_strong'))
        .lineHeight(24)
        .width('100%')
        .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
        .margin({ top: 14 })

      if (this.detail !== null && this.detail.article.tags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.detail.article.tags, (tag: string) => {
            Text(`#${normalizeCommunityText(tag)}`)
              .fontSize(10)
              .fontColor(this.accent())
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(7)
              .padding({ left: 7, right: 7, top: 4, bottom: 4 })
              .margin({ right: 6, top: 6 })
          }, (tag: string) => tag)
        }
        .width('100%')
        .margin({ top: 8 })
      }

      Row() {
        this.statLine($r('app.media.eye'),
          `${this.detail !== null ? this.detail.article.viewCount : 0}${this.t($r('app.string.community_views_suffix'))}`)
        this.statLine($r('app.media.heart'),
          `${this.detail !== null ? this.detail.article.likeCount : 0}${this.t($r('app.string.community_likes_suffix'))}`)
        this.statLine($r('app.media.message_square'),
          `${this.detail !== null ? this.detail.article.commentCount : 0}${this.t($r('app.string.community_comments_suffix'))}`)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 14 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: UiTokens.pageHMargin, right: UiTokens.pageHMargin,
      top: UiTokens.topInset, bottom: 6
    })
  }

  @Builder
  commentRow(comment: CommunityComment, nested: boolean) {
    Row() {
      this.avatar(comment.authorName, comment.authorAvatarUrl,
        false, nested ? 28 : 34)
      Column() {
        Row({ space: 6 }) {
          Text(comment.authorName.length > 0
            ? comment.authorName : this.t($r('app.string.community_user')))
            .fontSize(UiTokens.fsSecondary)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary_strong'))
            .maxLines(1)
          if (comment.accepted) {
            Text($r('app.string.community_accepted'))
              .fontSize(10)
              .fontColor(this.accent())
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(7)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          }
        }
        .alignItems(VerticalAlign.Center)

        Text(removeCommunityEmoji(comment.content))
          .fontSize(UiTokens.fsBody)
          .fontColor($r('app.color.text_primary_strong'))
          .lineHeight(22)
          .width('100%')
          .margin({ top: 5 })

        Text(`${formatCommunityDate(comment.createdAt)} · ${comment.likeCount}${this.t($r('app.string.community_likes_unit'))}`)
          .fontSize(UiTokens.fsChip)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 4 })

        // 回复（一级；对齐 7378 的嵌套渲染，深层回复折叠在一级之下）
        ForEach(comment.replies, (reply: CommunityComment) => {
          Row() {
            this.avatar(reply.authorName, reply.authorAvatarUrl, false, 26)
            Column() {
              Text(reply.authorName.length > 0
                ? reply.authorName : this.t($r('app.string.community_user')))
                .fontSize(UiTokens.fsCaption)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary_strong'))
              Text(removeCommunityEmoji(reply.content))
                .fontSize(UiTokens.fsSecondary)
                .fontColor($r('app.color.text_secondary'))
                .lineHeight(20)
                .width('100%')
                .margin({ top: 3 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ top: 10 })
        }, (reply: CommunityComment) => reply.id)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({
      left: UiTokens.pageHMargin, right: UiTokens.pageHMargin,
      top: 12, bottom: 12
    })
    .margin({ left: nested ? 24 : 0 })
  }

  // 底部互动条：评论输入 + 发送 + 点赞 + 分享（悬浮在列表之下，贴底部并让开手势条）
  @Builder
  dockBar() {
    // 形态与几何完全对齐聊天页 composerBar：外层 Column 居中、行高交给栏体内容区
    // （栏体本体 52vp、内容区 = UiTokens.chatComposerBarInner），行内左右 padding 3vp；
    // 竖直方向不留内边距、不写死行高 —— 写死行高 + 上下内边距会把内容压扁、贴底（"没有垂直居中"）。
    Column() {
      Row({ space: 8 }) {
        TextInput({ placeholder: $r('app.string.community_comment_placeholder'), text: $$this.commentText })
          .layoutWeight(1)
          .height(42)
          .fontSize(UiTokens.fsBody)
          .placeholderFont({ size: UiTokens.fsBody })
          .caretColor(this.accent())
          // 透明：让悬浮栏的材质层（磨砂 + 受光渐层）连续透出，而不是被一层实底盖住
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.input_text'))
          .placeholderColor($r('app.color.placeholder'))
          .borderRadius(21)
          .enterKeyType(EnterKeyType.Send)
          .onSubmit((): void => {
            this.submitComment();
          })

        if (this.commentText.trim().length > 0) {
          if (this.submitting) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color(this.accent())
              .margin({ right: 6 })
          } else {
            Image($r('app.media.send'))
              .width(22).height(22)
              .fillColor(this.accent())
              .padding(8)
              .onClick((): void => {
                this.submitComment();
              })
          }
        }

        Image(this.detail !== null && this.detail.article.liked
          ? $r('app.media.heart_fill') : $r('app.media.heart'))
          .width(22)
          .height(22)
          .fillColor(this.detail !== null && this.detail.article.liked
            ? this.accent() : $r('app.color.text_tertiary'))
          .padding(8)
          .onClick((): void => {
            this.like();
          })

        Image($r('app.media.link'))
          .width(21).height(21)
          .fillColor($r('app.color.text_tertiary'))
          .padding(8)
          .onClick((): void => {
            this.share();
          })
      }
      .width('100%')
      .padding({ left: 3, right: 3 })
      .alignItems(VerticalAlign.Center)
      .height(UiTokens.chatComposerBarInner)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    // 底色/圆角/离底/材质一律交给 barFloatingStyle（官方口径：设了悬浮材质后不要再叠
    // barBackgroundColor/barBackgroundBlurStyle，会遮住材质）
  }

  // 列表末端让位高度：悬浮条带 + 离底间距 + 系统导航区 + 一点呼吸（spacer 落在滚动内容里）
  private dockInset(): number {
    return DOCK_BAR_H + DOCK_BOTTOM_MARGIN + this.navInset + 8;
  }
}
