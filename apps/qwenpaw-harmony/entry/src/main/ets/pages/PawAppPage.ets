/*
 * QwenPaw App 详情（内嵌 Web）—— 对齐 7378 app/pawapp/[id].tsx（从 App Center 打开扩展页面）。
 * 用 ArkWeb 的 Web 组件打开 {baseUrl}/apps/{id}，并在**文档加载前**注入脚本，给同源
 * fetch / XHR 补 Authorization 与 X-Agent-Id —— 等价 RN 的 injectedJavaScriptBeforeContentLoaded
 * + authenticationBridge（官方 FAQ faqs-arkweb-59：加载前注入用 javaScriptOnDocumentStart）。
 */

import { HdsNavDestination, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { webview } from '@kit.ArkWeb';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { url } from '@kit.ArkTS';
import { QpConnection, loadConnection } from '../services/ConnectionStore';
import { ThemeManager, ThemeSnapshot, ThemeListener } from '../theme/ThemeManager';
import { UiTokens } from '../theme/UiTokens';
import { LengthMetrics } from '@kit.ArkUI';

@Builder
export function PawAppPageBuilder(_name: string, param: Object) {
  PawAppPage({ params: param })
}

@Component
export struct PawAppPage {
  params: Object = new Object();
  @State appId: string = '';
  @State target: string = '';
  @State injected: string = '';
  @State ready: boolean = false;
  @State opened: boolean = false;
  @State failed: string = '';
  @State isDark: boolean = false;
  @State theme: ThemeSnapshot = ThemeManager.get().snapshot();
  private controller: webview.WebviewController = new webview.WebviewController();
  private themeListener: ThemeListener | null = null;

  aboutToAppear(): void {
    const rec: Record<string, Object> = this.params as Record<string, Object>;
    const id: Object = rec['appId'];
    this.appId = typeof id === 'string' ? id as string : '';
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.isDark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.themeListener = (snap: ThemeSnapshot): void => {
      this.theme = snap;
    };
    ThemeManager.get().subscribe(this.themeListener);
    ThemeManager.get().load(ctx).then((): void => {
      this.theme = ThemeManager.get().snapshot();
    });
    loadConnection(ctx).then((conn: QpConnection | null): void => {
      if (conn === null) {
        this.failed = this.t($r('app.string.pawapp_no_connection'));
        return;
      }
      this.target = `${conn.baseUrl}/apps/${encodeURIComponent(this.appId)}`;
      this.injected = this.bridge(conn);
      this.ready = true;
    });
  }

  aboutToDisappear(): void {
    if (this.themeListener !== null) {
      ThemeManager.get().unsubscribe(this.themeListener);
      this.themeListener = null;
    }
  }

  private t(res: Resource): string {
    try {
      const host: common.Context = this.getUIContext().getHostContext() as common.Context;
      return host.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  private accent(): string {
    return this.isDark ? this.theme.accentDark : this.theme.accent;
  }

  // 同源判定用 origin（官方 @ohos.url：protocol + host + port）
  private originOf(base: string): string {
    try {
      const u: url.URL = new url.URL(base);
      const port: string = u.port.length > 0 ? `:${u.port}` : '';
      return `${u.protocol}//${u.hostname}${port}`;
    } catch (e) {
      return base;
    }
  }

  // 文档加载前注入：仅对同源请求补鉴权头（对齐 7378 authenticationBridge 行为）
  private bridge(conn: QpConnection): string {
    const origin: string = this.originOf(conn.baseUrl);
    const agentId: string = conn.agentId.length > 0 ? conn.agentId : 'default';
    return `(function(){var allowedOrigin=${JSON.stringify(origin)};var token=${JSON.stringify(conn.token)};var agentId=${JSON.stringify(agentId)};`
      + `var same=function(input){try{var raw=(typeof input==='string')?input:input.url;return new URL(raw,window.location.href).origin===allowedOrigin;}catch(e){return false;}};`
      + `var of=window.fetch.bind(window);window.fetch=function(input,init){init=init||{};if(!same(input))return of(input,init);`
      + `var h=new Headers(init.headers||{});if(token)h.set('Authorization','Bearer '+token);h.set('X-Agent-Id',agentId);`
      + `return of(input,Object.assign({},init,{headers:h,credentials:'include'}));};`
      + `var oo=XMLHttpRequest.prototype.open;var os=XMLHttpRequest.prototype.send;`
      + `XMLHttpRequest.prototype.open=function(m,u){this.__qpwSame=same(u);return oo.apply(this,arguments);};`
      + `XMLHttpRequest.prototype.send=function(){if(this.__qpwSame){if(token)this.setRequestHeader('Authorization','Bearer '+token);this.setRequestHeader('X-Agent-Id',agentId);}return os.apply(this,arguments);};})();`;
  }

  build() {
    HdsNavDestination() {
      Stack() {
        if (this.failed.length > 0) {
          Column() {
            Text(this.failed)
              .fontSize(UiTokens.fsBody)
              .fontColor($r('app.color.status_error'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.ready) {
          Web({ src: this.target, controller: this.controller })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            // 文档加载前注入（官方 FAQ：加载前用 javaScriptOnDocumentStart）
            .javaScriptOnDocumentStart([{ script: this.injected, scriptRules: ['*'] }])
            .onPageEnd((): void => {
              this.opened = true;
            })
            .width('100%')
            .height('100%')
        }

        if (this.ready && !this.opened) {
          Column() {
            LoadingProgress()
              .width(36)
              .height(36)
              .color(this.accent())
            Text($r('app.string.pawapp_loading'))
              .fontSize(UiTokens.fsCaption)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ top: 10 })
            Text($r('app.string.pawapp_hint'))
              .fontSize(UiTokens.fsCaption)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ top: 6 })
              .padding({ left: 24, right: 24 })
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.page_bg'))
        }
      }
      .width('100%')
      .height('100%')
    }
    // 内容也扩到安全区外（布局级，与 expandSafeArea 同设时优先）：二级页四边都扩，
    // 否则下端/左右两侧会露出窗口底色（页面底部输入条一带表现为黑带）
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],
      [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM, LayoutSafeAreaEdge.START, LayoutSafeAreaEdge.END])
    .titleBar({
      // 二级页各自配标题栏（含返回图标区）：静止态即磨砂 + 系统转场动画。
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
        originalStyle: {
          backgroundStyle: {
            blurRadius: 12.0,
            // 蒙层外扩必须写在**生效态**里：enableScrollEffect=false 时只生效 originalStyle，
            // 写在 scrollEffectStyle 里会被忽略、退回平台默认外扩（真机实测蒙层 822 → 标题栏底边
            // 710 之下多出 112px≈56vp），那段在工具条正下方留下一条中性灰带（浅色模式即"接缝"）；
            // 归零后蒙层与标题栏同底（710），渐隐在标题栏内完成，内容区不再被蒙层压到。
            maskExtraHeight: 0.0,
            backgroundColor: this.accent()
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            blurRadius: 12.0,
            backgroundColor: this.accent()
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        title: {
          mainTitle: this.appId,
          subTitle: $r('app.string.pawapp_subtitle')
        }
      },
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: false
    })
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM],
      [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
  }
}
