/*
 * 社区 tab —— 移植 PR #7378 app/(tabs)/community.tsx + features/community/components/*：
 *   文章流（作者、标题、摘要、封面、标签、点赞/评论/浏览/分享）+ 下拉刷新 + 滑到底自动翻页 + 加载/错误/空态。
 *   排序分段（推荐/最新）与分类胶囊**不在这里**：它们挂在标题栏工具条（Index 的 bottomBuilder）——
 *   那里才在标题栏材质作用域内（沉浸光感生效），且随 FREE 标题上滑一起上移、缩到 MINI 标题下方不消失；
 *   Index 持有 sort/type 状态，以 @Prop 同步进来（变更即重取，见 onFilterChanged）。
 * 数据源：AgentScope Platform 公开读（{Platform}/api/v1/community/articles）。
 *
 * 留白纪律：顶部留白必须落在**列表内容里**（首项 spacer），不能加在包住 List 的容器上 ——
 *   容器 padding 会裁掉视口，内容滚不到标题栏之下，沉浸与渐变模糊就无从生效。
 */

import { common } from '@kit.AbilityKit';
import { pushRoute, swapRoute } from '../services/NavPush';
import { rememberPage } from '../services/LastPage';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import {
  CommunityArticleSummary, CommunityListOptions, CommunityArticlePage,
  listCommunityArticles, likeCommunityArticle, communityArticleUrl, communityInitials,
  formatCommunityDate, normalizeCommunityText
} from '../services/CommunityService';
import { getPlatformAccessToken } from '../services/PlatformSession';
import { UiTokens } from '../theme/UiTokens';
import { PressCard } from './PressCard';
import { PRESS_SCALE, PressLatch, pressTouch } from '../theme/PressFx';
import { isDarkMode, accentColor } from '../theme/Accent';

const PAGE_SIZE: number = 12;

// 打开文章详情页的路由参数（router_map name = 'community-article'）：
// 详情页需要再 push 登录页，故随参数带上导航栈（与设置页 param.stack 同一口径）
export interface CommunityArticleParam {
  articleId: string;
  stack: NavPathStack;
}

// Platform 登录页路由参数（router_map name = 'platform-login'）：页面需自行换页/退回，故带栈
export interface PlatformLoginParam {
  returnTo: string;   // 空串 | 'compose' | 'deploy'
  stack: NavPathStack;
}

// 发布页路由参数（router_map name = 'community-compose'）：发布成功要 replace 成文章详情，故带栈
export interface CommunityComposeParam {
  stack: NavPathStack;
}

@Component
export struct CommunityTab {
  scroller: Scroller = new Scroller();
  navStack: NavPathStack = new NavPathStack();
  // 排序 / 分类：由标题栏工具条（Index）持有并单向同步（变更触发重取）
  @Prop @Watch('onFilterChanged') sort: string = 'recommended';
  @Prop @Watch('onFilterChanged') type: string = '';
  // 列表滚动位置上报（标题栏工具条据此判断"标题已收起"→ 整条上提贴标题）
  onScrollY: (y: number) => void = (): void => {};
  @State articles: CommunityArticleSummary[] = [];
  @State page: number = 1;
  @State hasMore: boolean = true;
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State pressed: number = -1;
  @State isDark: boolean = false;
  private latch: PressLatch = new PressLatch();
  // 请求版本号：过期响应丢弃（对齐 7378 requestVersion）
  private requestVersion: number = 0;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.isDark = isDarkMode(ctx);
    this.loadFirstPage(false);
  }

  // 标题栏里的排序/分类变了：重取第一页（版本号保证过期响应被丢弃）
  onFilterChanged(): void {
    this.loadFirstPage(false);
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
    return accentColor(this.isDark);
  }

  private async loadFirstPage(refresh: boolean): Promise<void> {
    const version: number = this.requestVersion + 1;
    this.requestVersion = version;
    if (refresh) {
      this.refreshing = true;
    } else {
      this.loading = true;
    }
    this.error = '';
    const options: CommunityListOptions = {
      page: 1,
      pageSize: PAGE_SIZE,
      sort: this.sort,
      type: this.type
    };
    try {
      const result: CommunityArticlePage = await listCommunityArticles(options);
      if (version !== this.requestVersion) {
        return;
      }
      this.articles = result.items;
      this.page = 1;
      this.hasMore = result.items.length < result.total;
    } catch (e) {
      if (version !== this.requestVersion) {
        return;
      }
      this.articles = [];
      this.error = (e as Error).message;
    } finally {
      if (version === this.requestVersion) {
        this.loading = false;
        this.refreshing = false;
      }
    }
  }

  private async loadMore(): Promise<void> {
    if (!this.hasMore || this.loading || this.loadingMore || this.refreshing) {
      return;
    }
    this.loadingMore = true;
    const nextPage: number = this.page + 1;
    const options: CommunityListOptions = {
      page: nextPage,
      pageSize: PAGE_SIZE,
      sort: this.sort,
      type: this.type
    };
    try {
      const result: CommunityArticlePage = await listCommunityArticles(options);
      const known: string[] = this.articles.map((a: CommunityArticleSummary): string => a.id);
      const merged: CommunityArticleSummary[] = this.articles.slice();
      for (const item of result.items) {
        if (known.indexOf(item.id) < 0) {
          merged.push(item);
        }
      }
      this.articles = merged;
      this.page = nextPage;
      this.hasMore = nextPage * PAGE_SIZE < result.total;
    } catch (e) {
      this.hasMore = false;
    } finally {
      this.loadingMore = false;
    }
  }

  private openArticle(articleId: string): void {
    const param: CommunityArticleParam = { articleId: articleId, stack: this.navStack };
    // 记下「最后打开的文章」：分栏下切走页签再切回来，右栏恢复这篇文章（见 pages/Index.enterTab）
    rememberPage(2, 'community-article', articleId);
    swapRoute(this.navStack, 'community-article', param);
  }

  private shareArticle(article: CommunityArticleSummary): void {
    const url: string = communityArticleUrl(article.id);
    try {
      const data: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.TEXT,
        content: `${article.title}\n${url}`,
        title: article.title
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      controller.show(this.getUIContext().getHostContext() as common.UIAbilityContext, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL
      }).catch((): void => {
        this.getUIContext().getPromptAction().showToast({ message: url });
      });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: url });
    }
  }

  private async interactArticle(article: CommunityArticleSummary): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const token: string = await getPlatformAccessToken(ctx);
    if (token.length === 0) {
      this.getUIContext().showAlertDialog({
        title: this.t($r('app.string.community_login_needed_title')),
        message: this.t($r('app.string.community_login_needed_copy')),
        primaryButton: {
          value: this.t($r('app.string.common_cancel')),
          action: (): void => {
          }
        },
        secondaryButton: {
          value: this.t($r('app.string.community_login_action')),
          action: (): void => {
            pushRoute(this.navStack, 'platform-login');
          }
        }
      });
      return;
    }
    try {
      const updated: CommunityArticleSummary = await likeCommunityArticle(ctx, article.id);
      const next: CommunityArticleSummary[] = [];
      for (const item of this.articles) {
        if (item.id === article.id) {
          item.liked = updated.liked;
          item.likeCount = updated.likeCount;
        }
        next.push(item);
      }
      this.articles = next;
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({
        message: this.t($r('app.string.community_like_failed'))
      });
    }
  }

  build() {
    Column() {
      // 排序分段 / 分类胶囊在标题栏工具条里（Index bottomBuilder）：本页只渲染文章流与状态块。
      // 顶部留白落在列表内容里（首项 spacer）——容器 padding 会裁掉视口，内容滚不到标题栏之下，
      // 沉浸与渐变模糊就不生效（本页上一版正是栽在这里）。
      if (this.loading) {
        Column() {
          this.stateBlock($r('app.string.community_loading'), '', false)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: UiTokens.communityTopInset, left: UiTokens.pageHMargin, right: UiTokens.pageHMargin })
      } else if (this.error.length > 0) {
        Column() {
          this.stateBlock($r('app.string.community_unavailable'), this.error, true)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: UiTokens.communityTopInset, left: UiTokens.pageHMargin, right: UiTokens.pageHMargin })
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          List({ scroller: this.scroller }) {
            // 首项 spacer = 标题栏下缘 + 工具条 + 呼吸边距（内容可滚到标题栏/工具条之下 → 渐变模糊生效）
            ListItem() {
              Column().width('100%').height(UiTokens.communityTopInset)
            }
            ForEach(this.articles, (article: CommunityArticleSummary, idx: number) => {
              ListItem() {
                this.postCard(article, idx)
              }
            }, (article: CommunityArticleSummary) => article.id)

            if (this.articles.length === 0) {
              ListItem() {
                Column() {
                  Image($r('app.media.qwenpaw_symbol'))
                    .width(60)
                    .height(58)
                    .draggable(false)
                  Text($r('app.string.community_empty_title'))
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.text_primary_strong'))
                    .margin({ top: 10 })
                  Text($r('app.string.community_empty_copy'))
                    .fontSize(UiTokens.fsSecondary)
                    .fontColor($r('app.color.text_tertiary'))
                    .textAlign(TextAlign.Center)
                    .lineHeight(19)
                    .margin({ top: 6 })
                }
                .width('100%')
                .padding({ top: 40, left: 40, right: 40 })
              }
            }

            if (this.loadingMore) {
              ListItem() {
                Row() {
                  LoadingProgress()
                    .width(22)
                    .height(22)
                    .color(this.accent())
                }
                .width('100%')
                .height(52)
                .justifyContent(FlexAlign.Center)
              }
            }
            // 末项 spacer：让开底部悬浮页签（必须放在列表内容里 —— 加在 List 容器上会裁掉视口，
            // 内容再也滚不到页签栏之下，页签周围就露出一片无内容的黑带）
            ListItem() {
              Column().width('100%').height(UiTokens.bottomInset)
            }
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .onDidScroll((): void => {
            const offset: OffsetResult = this.scroller.currentOffset();
            this.onScrollY(offset.yOffset as number);
          })
          .onReachEnd((): void => {
            this.loadMore();
          })
        }
        .width('100%')
        .layoutWeight(1)
        .pullToRefresh(true)
        .onRefreshing((): void => {
          this.loadFirstPage(true);
        })
      }
    }
    .width('100%')
    .height('100%')
    // 页面根部不挂左右留白：留白挂在包住 List 的容器上会把 List 视口一起缩窄，
    // 卡片铺满视口 → 按压照亮越过卡片边界即被视口裁掉（硬截断）。留白下移到内容里
    // （帖子卡走 PressCard.insetH，状态块各自留白），视口铺满屏宽。
    // 页面底色：底部悬浮页签栏周围与手势条一带靠它托底（缺了会露出窗口默认黑带）
    .backgroundColor($r('app.color.page_bg'))
    .alignItems(HorizontalAlign.Start)
  }

  // 加载中 / 错误态（对齐 7378 的居中状态块 + 重新加载）
  @Builder
  stateBlock(title: Resource, copy: string, retry: boolean) {
    Column() {
      if (retry) {
        Column() {
          Image($r('app.media.refresh_cw'))
            .width(25).height(25)
            .fillColor(this.accent())
        }
        .width(54)
        .height(54)
        .borderRadius(17)
        .backgroundColor($r('app.color.card_bg'))
        .justifyContent(FlexAlign.Center)
        .margin({ bottom: 12 })
      } else {
        LoadingProgress()
          .width(28)
          .height(28)
          .color(this.accent())
          .margin({ bottom: 12 })
      }
      Text(title)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary_strong'))
      if (copy.length > 0) {
        Text(copy)
          .fontSize(UiTokens.fsSecondary)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
          .lineHeight(19)
          .margin({ top: 6 })
      }
      if (retry) {
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
            this.loadFirstPage(false);
          })
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
  postCard(article: CommunityArticleSummary, idx: number) {
    // 整卡按压走 PressCard（与 GlassCard 逐项同款：Button 外壳 + card_glass + 圆角 + 点光源）——
    // 卡片本体必须是 Button 才有完整的发光/受光反馈；此前的 Column 外壳只能看到收缩、没有边缘照亮。
    // 卡片内的动作键各自 stopPropagation，所以整卡按压与键位按压不会同时触发。
    PressCard({
      onTap: (): void => {
        this.openArticle(article.id);
      },
      // 帖卡比会话/智能体的卡高得多（~283vp vs ~137vp），点光源在卡片正中心、默认受光羽化范围够不到
      // 上下边缘 → 边缘照亮整块失效。改用 BORDER 受光（沿组件边界直接发光）让整圈边界都亮。
      edgeGlow: true
    }) {
    Column() {
      // 作者行
      Row() {
        this.avatar(article.authorName, article.authorAvatarUrl,
          article.identityBadge !== null && article.identityBadge.code === 'official', 42)
        Column() {
          Row({ space: 4 }) {
            Text(article.authorName.length > 0
              ? article.authorName : this.t($r('app.string.community_user')))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary_strong'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 190 })
            if (article.identityBadge !== null) {
              Image($r('app.media.shield_check'))
                .width(14).height(14)
                .fillColor(this.accent())
            }
          }
          .alignItems(VerticalAlign.Center)

          Text(`${formatCommunityDate(article.publishedAt)} · ${article.articleTypeLabel}`)
            .fontSize(UiTokens.fsChip)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 8 })

        if (article.isFeatured) {
          Text($r('app.string.community_featured'))
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.accent())
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(9)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 正文区（点按打开详情）
      Column() {
        Text(normalizeCommunityText(article.title))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary_strong'))
          .lineHeight(24)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (normalizeCommunityText(article.summary).length > 0) {
          Text(normalizeCommunityText(article.summary))
            .fontSize(UiTokens.fsSecondary)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(20)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 7 })
            .width('100%')
        }
        if (article.coverUrl.length > 0) {
          Image(article.coverUrl)
            .width('100%')
            .aspectRatio(16 / 9)
            .objectFit(ImageFit.Cover)
            .borderRadius(15)
            .backgroundColor($r('app.color.card_bg'))
            .margin({ top: 11 })
        }
        this.metaTags(article)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 12 })

      // 动作条上方的分隔线：用 Divider 组件，**不要用 border**
      //（官方点光源口径：受光组件设了 border 的颜色/宽度会覆盖点光源效果；实测卡内动作条的
      //  `border({width:{top:1}})` 会让整卡的边缘照亮完全失效——基准卡 GlassCard 内含无 border 才有 Δp95+23）
      Divider()
        .strokeWidth(1)
        .color($r('app.color.line'))
        .width('100%')
        .margin({ top: 10 })

      // 动作条（点赞 / 评论 / 浏览 / 分享）
      Row() {
        this.cardAction($r('app.media.heart'), $r('app.media.heart'),
          article.liked, article.likeCount.toString(), idx * 10 + 1, (): void => {
            this.interactArticle(article);
          })
        this.cardAction($r('app.media.message_square'), $r('app.media.message_square'),
          false, article.commentCount.toString(), idx * 10 + 2, (): void => {
            this.openArticle(article.id);
          })
        this.cardAction($r('app.media.eye'), $r('app.media.eye'),
          false, article.viewCount.toString(), idx * 10 + 3, (): void => {
            this.openArticle(article.id);
          })
        this.cardAction($r('app.media.send'), $r('app.media.send'),
          false, this.t($r('app.string.community_share')), idx * 10 + 4, (): void => {
            this.shareArticle(article);
          })
      }
      .width('100%')
      .height(44)
    }
    .width('100%')
    // 卡片的外观（玻璃底/圆角/内边距）与按压反馈都由外层 PressCard 的 Button 提供，
    // 这里只负责内容排布 —— 避免"外层有底色、内层发光"（受光组件需要底色 + 圆角才看得到边缘照亮）
    .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  cardAction(onIcon: Resource, offIcon: Resource, active: boolean, label: string,
    idx: number, onTap: () => void) {
    Row({ space: 4 }) {
      Image(active ? onIcon : offIcon)
        .width(18).height(18)
        .fillColor(active ? this.accent() : $r('app.color.text_tertiary'))
      Text(label)
        .fontSize(UiTokens.fsChip)
        .fontColor(active ? this.accent() : $r('app.color.text_tertiary'))
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    // 动作键按压 = 跟手收缩 + 变暗（对齐 7378 CommunityPostCard：pressed && opacity 0.48）。
    // 这里**不挂点光源**：官方点光源的受光类型是"羽化描边"，四个并排小按钮各自一圈光边，
    // 观感就是"方形按钮框"（被指出太丑）。
    .scale({ x: this.pressed === idx ? PRESS_SCALE : 1, y: this.pressed === idx ? PRESS_SCALE : 1 })
    .opacity(this.pressed === idx ? 0.55 : 1)
    .onTouch((e: TouchEvent): void => {
      // 阻止冒泡：动作键自己按压时不要再触发整卡收缩（否则一次按下两处形变）
      e.stopPropagation();
      pressTouch(this.getUIContext(), e, this.latch, (v: boolean): void => {
        this.pressed = v ? idx : -1;
      });
    })
    .onClick((): void => {
      onTap();
    })
  }

  // 标签区（问答状态 / 话题标签 / 关联资源计数）
  @Builder
  metaTags(article: CommunityArticleSummary) {
    if (article.qaStatus.length > 0 || article.tags.length > 0 ||
      article.relatedSkillIds.length > 0 || article.relatedPluginIds.length > 0) {
      Flex({ wrap: FlexWrap.Wrap }) {
        if (article.qaStatus.length > 0) {
          Text(article.qaStatus === 'solved'
            ? $r('app.string.community_qa_solved') : $r('app.string.community_qa_open'))
            .fontSize(10)
            .fontColor(Color.White)
            .backgroundColor(this.accent())
            .borderRadius(7)
            .padding({ left: 7, right: 7, top: 4, bottom: 4 })
            .margin({ right: 6, top: 6 })
        }
        ForEach(article.tags.slice(0, 3), (tag: string) => {
          Text(`#${normalizeCommunityText(tag)}`)
            .fontSize(10)
            .fontColor(this.accent())
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(7)
            .padding({ left: 7, right: 7, top: 4, bottom: 4 })
            .margin({ right: 6, top: 6 })
        }, (tag: string) => tag)
        if (article.relatedSkillIds.length > 0) {
          Text(`${article.relatedSkillIds.length} 个 Skill`)
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(7)
            .padding({ left: 7, right: 7, top: 4, bottom: 4 })
            .margin({ right: 6, top: 6 })
        }
        if (article.relatedPluginIds.length > 0) {
          Text(`${article.relatedPluginIds.length} 个 Plugin`)
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(7)
            .padding({ left: 7, right: 7, top: 4, bottom: 4 })
            .margin({ right: 6, top: 6 })
        }
      }
      .width('100%')
      .margin({ top: 4 })
    }
  }
}
