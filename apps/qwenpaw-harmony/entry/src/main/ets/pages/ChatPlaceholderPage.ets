/*
 * 分栏右栏的空态占位页（平板/PC 横屏、会话页分栏时）。
 * 平台行为：Navigation 分栏下未 push 页面时右侧为空白（深色下观感即一片纯黑）。
 * 官方 FAQ《Navigation 在分栏模式下如何给右侧空白设置默认页面》给两条路：push 默认页 / splitPlaceholder；
 * 这里用 push 默认页 —— 可选面更宽，也能承载品牌形象。
 * 占位页只作展示：不出标题栏、不抢焦点；返回键在此页消费掉，避免把占位页弹出后右栏又变空白。
 */

import { HdsNavDestination } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { UiTokens } from '../theme/UiTokens';

@Builder
export function ChatPlaceholderPageBuilder(_name: string, param: Object) {
  ChatPlaceholderPage({ params: param })
}

@Component
export struct ChatPlaceholderPage {
  params: Object = new Object();

  private t(res: Resource): string {
    try {
      const host: common.Context = this.getUIContext().getHostContext() as common.Context;
      return host.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  build() {
    HdsNavDestination() {
      Column() {
        Image($r('app.media.qwenpaw_ip'))
          .width(180)
          .objectFit(ImageFit.Contain)
          .draggable(false)
        Text($r('app.string.chat_placeholder_hint'))
          .fontSize(UiTokens.fsBody)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 16 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor($r('app.color.page_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM],
        [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
    }
    // 占位页不显标题栏（也就没有返回键，不会抢焦点）
    .hideTitleBar(true)
    // 返回键在本页消费：占位页被弹出后右栏又会变回空白，等于没占位
    .onBackPressed((): boolean => {
      return true;
    })
  }
}
