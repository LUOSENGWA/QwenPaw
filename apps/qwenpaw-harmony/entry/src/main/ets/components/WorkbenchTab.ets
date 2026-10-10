/*
 * 工作台 tab —— 一期 hub（对齐 PR #7378 移动端 workbench 的定位）：
 * 连接状态 + 连接与设置（路由 → SettingsPage）+ 关于 + 审批。
 * 审批：GET /api/console/push-messages 真数据；有待审批且数量变化时发系统通知。
 */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { emitter } from '@kit.BasicServicesKit';
import { loadConnection, QpConnection } from '../services/ConnectionStore';
import { hostOf } from '../services/PairingModel';
import { fetchApprovals, ApprovalInfo } from '../services/ApprovalsService';
import { AGENT_CHANGE_EVENT } from '../services/AgentsService';
import { publishNotice, requestNotificationPermission } from '../services/NotifyService';
import { UiTokens } from '../theme/UiTokens';
import { GlassCard } from './GlassCard';

export const CONN_CHANGE_EVENT: string = 'qp_conn_change';

@Component
export struct WorkbenchTab {
  navStack: NavPathStack = new NavPathStack();
  @State connHost: string = '';
  @State connected: boolean = false;
  @State approvals: ApprovalInfo[] = [];

  private static readonly PREF_NAME: string = 'notify';
  private static readonly KEY_LAST_COUNT: string = 'lastApprovalCount';
  private connListener: (data: emitter.EventData) => void = (_data: emitter.EventData): void => {};
  private agentListener: (data: emitter.EventData) => void = (_data: emitter.EventData): void => {};

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.loadConn(ctx);
    this.connListener = (_data: emitter.EventData): void => {
      this.loadConn(ctx);
    };
    // 智能体切换后审批按新 agent 重载（X-Agent-Id）
    this.agentListener = (_data: emitter.EventData): void => {
      this.loadConn(ctx);
    };
    emitter.on(CONN_CHANGE_EVENT, this.connListener);
    emitter.on(AGENT_CHANGE_EVENT, this.agentListener);
  }

  aboutToDisappear(): void {
    emitter.off(CONN_CHANGE_EVENT, this.connListener);
    emitter.off(AGENT_CHANGE_EVENT, this.agentListener);
  }

  private loadConn(ctx: common.UIAbilityContext): void {
    loadConnection(ctx).then((conn: QpConnection | null) => {
      if (conn !== null) {
        this.connected = true;
        this.connHost = hostOf(conn.baseUrl);
        this.refreshApprovals(conn, ctx);
      } else {
        this.connected = false;
        this.connHost = '';
        this.approvals = [];
      }
    });
  }

  private async refreshApprovals(conn: QpConnection, ctx: common.UIAbilityContext): Promise<void> {
    try {
      const list: ApprovalInfo[] = await fetchApprovals(conn.baseUrl, conn.token, conn.agentId);
      this.approvals = list;
      await this.notifyIfNew(ctx, list.length);
    } catch (e) {
      // 审批读取失败不打断页面
    }
  }

  // 数量较上次已通知时增长 → 发系统通知（避免每次进入页面重复打扰）
  private async notifyIfNew(ctx: common.UIAbilityContext, count: number): Promise<void> {
    if (count <= 0) {
      return;
    }
    try {
      const pref: preferences.Preferences = await preferences.getPreferences(ctx,
        WorkbenchTab.PREF_NAME);
      const last: number = (await pref.get(WorkbenchTab.KEY_LAST_COUNT, -1)) as number;
      if (last === count) {
        return;
      }
      await pref.put(WorkbenchTab.KEY_LAST_COUNT, count);
      await pref.flush();
      const ok: boolean = await requestNotificationPermission(ctx);
      if (ok) {
        await publishNotice(ctx, this.t($r('app.string.notify_approval_title')),
          this.t($r('app.string.notify_approval_body')).replace('%d', count.toString()));
      }
    } catch (e) {
      // 通知失败不影响页面
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

  @Builder
  hubRow(titleRes: Resource, hintRes: ResourceStr | null, arrow: boolean, onTap: () => void) {
    HubRow({ titleRes: titleRes, hintRes: hintRes, arrow: arrow, onTap: onTap })
  }

  build() {
    Column() {
      // 大标题（FREE 标题栏）已显示 tab 名，页内不再重复
      // 连接状态卡（只读信息块：与「会话」页状态卡同款玻璃块，不加按压反馈）
      Row() {
        Circle()
          .width(10)
          .height(10)
          .fill(this.connected ? $r('app.color.status_success') : $r('app.color.status_idle'))
          .margin({ right: 8 })
        Text(this.connected ? this.connHost : $r('app.string.wb_not_connected'))
          .fontSize(14)
          .fontColor(this.connected ? $r('app.color.status_success') : $r('app.color.status_idle'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding(UiTokens.cardPad)
      .borderRadius(UiTokens.cardRadius)
      .backgroundColor($r('app.color.card_glass'))
      .margin({ top: UiTokens.cardVGap, bottom: UiTokens.cardVGap })

      this.hubRow($r('app.string.workbench_conn'), $r('app.string.workbench_conn_hint'), true, () => {
        this.navStack.pushPath({ name: 'settings' });
      })

      this.hubRow($r('app.string.workbench_about'), null, false, () => {
        this.getUIContext().showAlertDialog({
          title: $r('app.string.about_title'),
          message: $r('app.string.about_message'),
          confirm: { value: 'OK', action: () => {} }
        });
      })

    }
    .width('100%')
    .constraintSize({ minHeight: '100%' })
    .padding({ top: UiTokens.topInset, bottom: UiTokens.bottomInset, left: UiTokens.pageHMargin, right: UiTokens.pageHMargin })
    .backgroundColor($r('app.color.page_bg'))
  }

}

// 工作台 hub 行卡（卡片壳统一走 GlassCard：与「会话」「智能体」两页同一套玻璃卡与按压反馈）
@Component
export struct HubRow {
  titleRes: Resource = $r('app.string.tab_workbench');
  hintRes: ResourceStr | null = null;
  arrow: boolean = false;
  onTap: () => void = () => {};

  build() {
    GlassCard({
      // 本页容器已给 16vp 水平留白 → 卡片不再叠加，保证三页卡片边界一致（x=56..1260）
      insetH: 0,
      onTap: (): void => {
        this.onTap();
      }
    }) {
      Row() {
        Column() {
          Text(this.titleRes)
            .fontSize(UiTokens.fsBody)
            .fontWeight(FontWeight.Medium)
          if (this.hintRes !== null) {
            Text(this.hintRes)
              .fontSize(UiTokens.fsSecondary)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.arrow) {
          Text('›')
            .fontSize(22)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ left: 8 })
        }
      }
      .width('100%')
    }
  }
}
