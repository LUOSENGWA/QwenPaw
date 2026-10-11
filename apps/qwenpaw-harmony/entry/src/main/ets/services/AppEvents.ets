/*
 * 应用内深链事件总线（跨组件请求导航 + 连接状态广播）。
 * 场景一：App Center（工作台模块页里的组件）需要打开 pawapp 详情页，但它拿不到导航栈 ——
 * 由本总线把「要打开的 appId」暂存 + 发一条事件，根页面（Index）订阅后用自己的 NavPathStack
 * pushPath。参数用模块级变量传递，避免 emitter 载荷走无类型对象字面量（ArkTS 限制）。
 * 场景二：QwenPaw 服务端（连接）变化要让各处重取数据 —— 事件常量统一放这里，
 * 不让「谁发谁收」散落在各个组件文件里。
 */
import { emitter } from '@kit.BasicServicesKit';

export const PAWAPP_OPEN_EVENT: string = 'qwenpaw.pawapp.open';
export const NOTIFICATIONS_OPEN_EVENT: string = 'qwenpaw.notifications.open';
// 当前连接（QwenPaw 服务端）变了：新增 / 切换 / 移除后广播。订阅方据此重取按服务端取值的数据
// （工作台与会话页重取连接与列表、根页重取服务端主题色 —— 控制台主色存在服务端）。
export const CONN_CHANGE_EVENT: string = 'qp_conn_change';
// 「连接存储被别处改写」事件：设置页切换/移除/断开/重连后发一条，会话页据此重取当前连接并复核。
// 与 CONN_CHANGE_EVENT 分开，避免会话页自发自收（它自己也会发 CONN_CHANGE_EVENT）造成重连死循环。
export const CONN_STORE_EVENT: string = 'qp_conn_store_change';
// 请求切到某个底部页签：二级页（设置页「当前 Agent」等行）拿不到 HdsTabsController，
// 由根页（Index）订阅后用控制器切页（走与点击页签同一路径：onChange → enterTab）。
export const TAB_SWITCH_EVENT: string = 'qwenpaw.tab.switch';

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

export function requestNotifications(): void {
  emitter.emit(NOTIFICATIONS_OPEN_EVENT);
}

// 连接变化广播（由 ConnectionStore 在新增/切换/移除后调用）
export function notifyConnectionChange(): void {
  emitter.emit(CONN_CHANGE_EVENT);
}

// 「连接存储被改写」广播（由设置页/部署页在切换或断开后调用）
export function notifyConnectionStoreChange(): void {
  emitter.emit(CONN_STORE_EVENT);
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
