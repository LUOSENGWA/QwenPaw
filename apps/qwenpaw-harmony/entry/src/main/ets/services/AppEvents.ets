/*
 * 应用内深链事件总线（跨组件请求导航）。
 * 场景：App Center（工作台模块页里的组件）需要打开 pawapp 详情页，但它拿不到导航栈 ——
 * 由本总线把「要打开的 appId」暂存 + 发一条事件，根页面（Index）订阅后用自己的 NavPathStack
 * pushPath。参数用模块级变量传递，避免 emitter 载荷走无类型对象字面量（ArkTS 限制）。
 */
import { emitter } from '@kit.BasicServicesKit';

export const PAWAPP_OPEN_EVENT: string = 'qwenpaw.pawapp.open';
export const NOTIFICATIONS_OPEN_EVENT: string = 'qwenpaw.notifications.open';
// 请求切到某个底部页签：二级页（设置页「当前 Agent」等行）拿不到 HdsTabsController，
// 由根页（Index）订阅后用控制器切页（走与点击页签同一路径：onChange → enterTab）。
export const TAB_SWITCH_EVENT: string = 'qwenpaw.tab.switch';
// 请求打开「设置」弹窗（⋮ 菜单与工作台入口共用）：设置已是半模态弹窗、由根页承载，
// 二级入口（工作台）拿不到承载方状态，走本总线发一条事件。
export const SETTINGS_OPEN_EVENT: string = 'qwenpaw.settings.open';
// 分栏右栏空态占位页的路由名（router_map 注册）：会话分栏且未打开会话时压在最底
export const CHAT_PLACEHOLDER_ROUTE: string = 'chat-placeholder';

// pawapp 详情页的路由参数（router_map 里 name = 'pawapp'）
export interface PawAppParam {
  appId: string;
}

// 扫码配对页的路由参数（router_map 里 name = 'scan'）：页面需要自己 pop 回跳，故随参数带栈
// （与设置页 param.stack 同一口径）；调用方用 pushPathByName 的 onPop 回调接收配对结果。
export interface ScanRouteParam {
  stack: NavPathStack;
}

// 只带导航栈的通用页面入参（页面自行 pop / push，如平台部署页）
export interface StackOnlyParam {
  stack: NavPathStack;
}

let pendingAppId: string = '';
let pendingTabIndex: number = -1;

// 请求切到某个底部页签（0=会话 / 1=智能体 / 2=社区 / 3=工作台）
export function requestTab(index: number): void {
  pendingTabIndex = index;
  emitter.emit(TAB_SWITCH_EVENT);
}

export function takeTabRequest(): number {
  const value: number = pendingTabIndex;
  pendingTabIndex = -1;
  return value;
}

export function requestSettings(): void {
  emitter.emit(SETTINGS_OPEN_EVENT);
}

export function requestNotifications(): void {
  emitter.emit(NOTIFICATIONS_OPEN_EVENT);
}

export function requestPawApp(appId: string): void {
  pendingAppId = appId;
  emitter.emit(PAWAPP_OPEN_EVENT);
}

export function takePawAppRequest(): string {
  const value: string = pendingAppId;
  pendingAppId = '';
  return value;
}
