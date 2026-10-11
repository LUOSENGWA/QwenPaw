/*
 * 社区文章详情 —— 移植 PR #7378 app/community/[id].tsx：
 *   文章卡（类型/问答状态、标题、作者、封面、正文、标签、浏览/点赞/评论统计）+ 全部评论列表
 *   + 底部互动条（评论输入、发送、点赞、分享）。
 * 正文取 body_text（纯文本，可选中复制）——与 7378 同口径；body_html 不在这里渲染。
 * 键盘避让：官方 KeyboardAvoidMode.NONE + avoidAreaChange 自让底部（与聊天页同一套）。
 */

import { HdsNavDestination, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { window, KeyboardAvoidMode, curves, uiMaterial } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  CommunityComment, CommunityArticleDetail, getCommunityArticle, getCommunityComments,
  createCommunityComment, likeCommunityArticle, communityArticleUrl, communityInitials,
  formatCommunityDate, normalizeCommunityText, removeCommunityEmoji
} from '../services/CommunityService';
import { getPlatformAccessToken } from '../services/PlatformSession';
import { PlatformLoginParam } from '../components/CommunityTab';
import { ThemeManager, ThemeSnapshot, ThemeListener } from '../theme/ThemeManager';
import { UiTokens, pxPerVp } from '../theme/UiTokens';
import { areaWidthOf, BP_LG, CONTENT_MAX } from '../theme/Breakpoints';
import { pushRoute, popSelfOnBack, slideCoverTransition } from '../services/NavPush';

// 底部系统导航区保底值（vp）
const NAV_FALLBACK_INSET: number = 12;
// 底部互动条的渐变模糊：最大半径（fractionStops 末段比例见使用处）
const DOCK_BLUR_RADIUS: number = 40;
// 悬浮互动条本体高度（vp）= 聊天页同一口径（栏体高度 = chatComposerHeight + 1）与离底间距
const DOCK_BAR_H: number = 59;
const DOCK_BOTTOM_MARGIN: number = 12;

// 评论正文的一段：url = true 表示这段是链接（单独上色 + 可点）
interface LinkSpan {
  text: string;
  url: boolean;
}

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
  @State isDark: boolean = false;
  @State theme: ThemeSnapshot = ThemeManager.get().snapshot();
  private articleId: string = '';
  private stack: NavPathStack | null = null;
  // 二级页水平覆盖转场的位移（百分比）：由 NavPush.slideCoverTransition 驱动
  @State pageX: string = '0%';
  private themeListener: ThemeListener | null = null;
  private kbWindow: window.Window | null = null;
  private kbListener: ((data: window.AvoidAreaOptions) => void) | null = null;
  private prevKeyboardAvoidMode: KeyboardAvoidMode | null = null;

  // 大屏（平板/电脑）横屏判定：官方《页面布局场景》的横向断点；与会话页分栏同一判据
  //（宽度 ≥ 840vp 且横屏），同一设备上两处行为的切换条件保持一致
  @State pageW: number = 0;
  @State pageH: number = 0;

  private isWide(): boolean {
    return this.pageW >= BP_LG && this.pageW > this.pageH;
  }

  // 评论区栏宽：官方侧边栏口径 lg 档 = 屏宽的 40%，夹在 320–600vp 之间
  private commentsPaneW(): number {
    return Math.min(600, Math.max(320, Math.round(this.pageW * 0.4)));
  }

  private onPageArea = (_old: Area, now: Area): void => {
    this.pageW = areaWidthOf(now, this.pageW);
    const h: number = typeof now.height === 'number' ? now.height as number : 0;
    if (h > 0 && Math.abs(h - this.pageH) > 0.5) {
      this.pageH = h;
    }
  };

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
            pushRoute(stack, 'platform-login', param);
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
            // 分栏（官方《页面布局场景》侧边栏；图文详情 + 评论区即其典型场景）：
            // 左正文、右评论各自独立滚动，底部互动条仍通栏
            if (this.isWide()) {
              Row() {
                List() {
                  this.articleItems()
                  this.dockSpacerItem()
                }
                .layoutWeight(1)
                .height('100%')
                .scrollBar(BarState.Off)
                .linearGradientBlur(DOCK_BLUR_RADIUS, {
                  fractionStops: [[0, 0], [0, 0.88], [1, 1]],
                  direction: GradientDirection.Bottom
                })
                Column().width(1).height('100%').backgroundColor($r('app.color.line'))
                Column() {
                  // 右栏顶部让开沉浸标题栏带（与正文列首项 spacer 同口径）
                  Column().width('100%').height(UiTokens.topInset)
                  this.commentsHeaderRow()
                  List() {
                    this.commentItems()
                  }
                  .layoutWeight(1)
                  .width('100%')
                  .scrollBar(BarState.Off)
                  .linearGradientBlur(DOCK_BLUR_RADIUS, {
                    fractionStops: [[0, 0], [0, 0.88], [1, 1]],
                    direction: GradientDirection.Bottom
                  })
                }
                .width(this.commentsPaneW())
                .height('100%')
              }
              .width('100%')
              .height('100%')
              .alignItems(VerticalAlign.Top)
            } else {
            List() {
              ListItem() {
                this.articleBlock()
              }
                  ListItem() {
                    this.commentsHeaderRow()
                  }
                  this.commentItems()
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
      .onAreaChange(this.onPageArea)
    }
    // 内容也扩到安全区外（布局级，与 expandSafeArea 同设时优先）：二级页四边都扩，
    // 否则下端/左右两侧会露出窗口底色（页面底部输入条一带表现为黑带）
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],
      [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM, LayoutSafeAreaEdge.START, LayoutSafeAreaEdge.END])
    // 二级页转场：整页自右水平覆盖进来（退出滑回右侧）——见 services/NavPush.slideCoverTransition。
    // 系统默认档在分栏下动的是"内容区左边缘 0 → 分栏位"，观感从左侧摊过来（判"方向反了"），
    // 故改用官方 customTransition（NavDestinationTransitionDelegate）自己定方向。
    .customTransition((op: NavigationOperation, isEnter: boolean)
      : Array<NavDestinationTransition> | undefined => slideCoverTransition(op, isEnter,
        (v: string): void => { this.pageX = v; }))
    .translate({ x: this.pageX })
    // 返回键：系统侧滑与标题栏左上角返回按钮都投递到当前 NavDestination 的 onBackPressed
    //（官方 FAQ faqs-arkui-1117：该回调"支持拦截系统侧滑及 NavDestination 标题栏的返回事件"）；
    // 没挂它时标题栏返回按钮点了没有反应 —— 这里自己出栈并消费。
    .onBackPressed((): boolean => popSelfOnBack(this.stack))
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
    // 官方《页面布局场景》缩进布局：空间充足时内容列限宽居中（两侧留白建立层次）
    .constraintSize({ maxWidth: CONTENT_MAX })
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: UiTokens.pageHMargin, right: UiTokens.pageHMargin,
      top: UiTokens.topInset, bottom: 6
    })
  }

  // 正文列（列表项）：宽屏下内容列限宽并水平居中
  @Builder
  articleItems() {
    ListItem() {
      Row() {
        this.articleBlock()
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
  }

  // 评论标题行：单列模式下作为列表项随正文一起滚动，分栏模式下固定在评论区顶部
  @Builder
  commentsHeaderRow() {
    Row() {
      Text($r('app.string.community_all_comments'))
        .fontSize(UiTokens.fsBody)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary_strong'))
      Text(this.detail !== null ? this.detail.article.commentCount.toString() : '0')
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

  // 评论条目（列表项序列，含空态与末项 spacer）：两种布局共用
  @Builder
  commentItems() {
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
    this.dockSpacerItem()
  }

  // 末项 spacer：让开底部互动条（留白落在滚动内容里；容器 padding 会裁掉视口）
  @Builder
  dockSpacerItem() {
    ListItem() {
      Column().width('100%').height(this.dockInset())
    }
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

        // 评论正文：把其中的 URL 单独渲染成可点的链接（链接色 + 下划线，点击交系统打开）。
        // 7378 这里是纯文本（removeCommunityEmoji(comment.content)），URL 会以生字符串出现；
        // 改为按 URL 切段渲染，其余文字与 7378 一致（emoji 仍按社区口径剥掉）。
        Text() {
          ForEach(this.linkSpans(removeCommunityEmoji(comment.content)), (seg: LinkSpan) => {
            if (seg.url) {
              Span(seg.text)
                .fontColor(this.accent())
                .decoration({ type: TextDecorationType.Underline, color: this.accent() })
                .onClick((): void => {
                  this.openUrl(seg.text);
                })
            } else {
              Span(seg.text)
            }
          }, (seg: LinkSpan, idx: number) => `${idx}:${seg.url ? 'u' : 't'}`)
        }
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
              .width(40)
              .height(40)
              .color(this.accent())
          } else {
            // 发送 / 点赞 / 分享三键与聊天页附件键同一形态：Button 40×40 透明底 + 内嵌 20vp 图标。
            // 不能直接给 Image 加 padding —— padding 会缩掉绘制内容（此前 22vp 框 + 8vp padding
            // 实际只剩约 6vp 的图标，观感即"按钮太小"）。
            Button() {
              Image($r('app.media.send'))
                .width(20)
                .height(20)
                .fillColor(this.accent())
                .draggable(false)
            }
            .type(ButtonType.Normal)
            .width(40)
            .height(40)
            .padding(0)
            .backgroundColor(Color.Transparent)
            .onClick((): void => {
              this.submitComment();
            })
          }
        }

        Button() {
          Image(this.detail !== null && this.detail.article.liked
            ? $r('app.media.heart_fill') : $r('app.media.heart'))
            .width(20)
            .height(20)
            .fillColor(this.detail !== null && this.detail.article.liked
              ? this.accent() : $r('app.color.text_tertiary'))
            .draggable(false)
        }
        .type(ButtonType.Normal)
        .width(40)
        .height(40)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          this.like();
        })

        Button() {
          Image($r('app.media.link'))
            .width(20)
            .height(20)
            .fillColor($r('app.color.text_tertiary'))
            .draggable(false)
        }
        .type(ButtonType.Normal)
        .width(40)
        .height(40)
        .padding(0)
        .backgroundColor(Color.Transparent)
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

  // 把一段纯文本按 http(s):// 切成「文字 / 链接」段序列（供 Span 渲染成可点链接）。
  // 7378 正文与评论都是纯文本（生 URL 就是一串字符）；这里只把 URL 那一段单独上色 + 可点，
  // 其余文字原样。链接终点取到空白为止，尾部标点（)。,;）归回文字，避免吞进链接。
  private linkSpans(text: string): LinkSpan[] {
    const out: LinkSpan[] = [];
    let i: number = 0;
    while (i < text.length) {
      const at: number = text.indexOf('http', i);
      if (at < 0) {
        out.push({ text: text.substring(i), url: false });
        break;
      }
      const head: string = text.substring(at, at + 8).toLowerCase();
      if (!head.startsWith('http://') && !head.startsWith('https://')) {
        out.push({ text: text.substring(i, at + 4), url: false });
        i = at + 4;
        continue;
      }
      if (at > i) {
        out.push({ text: text.substring(i, at), url: false });
      }
      let end: number = at;
      while (end < text.length && ' \n\t'.indexOf(text.charAt(end)) < 0) {
        end++;
      }
      while (end > at && '),.;、，。）]'.indexOf(text.charAt(end - 1)) >= 0) {
        end--;
      }
      out.push({ text: text.substring(at, end), url: true });
      i = end;
    }
    if (out.length === 0) {
      out.push({ text: text, url: false });
    }
    return out;
  }

  // 链接交系统打开（应用内不内嵌浏览器；与「非文本文件交系统预览」同一取向）
  private openUrl(url: string): void {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      ctx.openLink(url, {}, (err: BusinessError): void => {
        if (err) {
          this.error = this.t($r('app.string.community_open_link_failed'));
        }
      });
    } catch (e) {
      this.error = this.t($r('app.string.community_open_link_failed'));
    }
  }
}
