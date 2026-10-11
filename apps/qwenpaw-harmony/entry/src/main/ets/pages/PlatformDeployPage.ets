/*
 * 平台部署（云端 QwenPaw）—— 移植 PR #7378 app/platform/deploy.tsx：
 *   检查已有部署 → 状态卡（三步进度）→ 部署日志（LIVE）→ 动作（部署 / 重新启动 / 切换版本 / 重置配对 / 打开控制台）。
 *   自动轮询：每 10s 取一次状态（隔次带日志），终态（running / failed / deleted）停止。
 *
 * 与 7378 的差异（有意）：云端实例的「自动安全配对」（platformGateway 协商 + platform 源连接直连）
 *   依赖 gateway 登录态透传与 platform 源连接模型，一期未移植 —— 本页负责创建与运维，
 *   配对仍走扫码 / 手输或在控制台完成；deploy 页的相关分支与按钮已按此收敛。
 */

import { HdsNavDestination, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import {
  PlatformDeployment, listPlatformDeployments, createPlatformDeployment, getPlatformDeployment,
  getPlatformDeploymentLogs, restartPlatformDeployment, resetPlatformQwenPawAuth,
  switchPlatformDeploymentVersion, deploymentStatusPresentation, deploymentCompatibility,
  DeploymentStatusPresentation, DeploymentCompatibility, deploymentErrorMessage,
  isTerminalDeployment, deploymentProgress
} from '../services/PlatformDeployService';
import { getPlatformAccessToken, platformLogout, PLATFORM_BASE_URL } from '../services/PlatformSession';
import { PlatformLoginParam } from '../components/CommunityTab';
import { IosGroup, IosRow } from '../components/IosList';
import { ThemeManager, ThemeSnapshot } from '../theme/ThemeManager';
import { UiTokens } from '../theme/UiTokens';
import { PRESS_SCALE, PressLatch, pressEffect, pressTouch } from '../theme/PressFx';
import { LengthMetrics } from '@kit.ArkUI';

const POLL_INTERVAL_MS: number = 10000;
const LOG_LINES: number = 40;

@Builder
export function PlatformDeployPageBuilder(_name: string, param: Object) {
  PlatformDeployPage({ params: param })
}

@Component
export struct PlatformDeployPage {
  params: Object = new Object();
  @State loggedIn: boolean = false;
  @State checking: boolean = true;
  @State appId: string = '';
  @State deployment: PlatformDeployment | null = null;
  @State logs: string[] = [];
  @State error: string = '';
  @State rateLimited: boolean = false;
  @State creating: boolean = false;
  @State recovering: boolean = false;
  @State resetting: boolean = false;
  @State switching: string = '';
  @State pressed: number = -1;
  @State isDark: boolean = false;
  @State theme: ThemeSnapshot = ThemeManager.get().snapshot();
  private stack: NavPathStack | null = null;
  private latch: PressLatch = new PressLatch();
  private timer: number = -1;
  private pollCount: number = 0;
  private inFlight: boolean = false;

  aboutToAppear(): void {
    const rec: Record<string, Object> = this.params as Record<string, Object>;
    const st: Object = rec['stack'];
    this.stack = (st === undefined || st === null) ? null : st as NavPathStack;
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.isDark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.check();
  }

  aboutToDisappear(): void {
    this.stopPoll();
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

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private stopPoll(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private startPoll(): void {
    this.stopPoll();
    this.timer = setInterval((): void => {
      this.pollCount = this.pollCount + 1;
      this.refresh(this.pollCount % 2 === 0);
    }, POLL_INTERVAL_MS);
  }

  private async check(): Promise<void> {
    this.checking = true;
    this.error = '';
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const token: string = await getPlatformAccessToken(ctx);
    if (token.length === 0) {
      this.loggedIn = false;
      this.checking = false;
      return;
    }
    this.loggedIn = true;
    try {
      const ids: string[] = await listPlatformDeployments(ctx);
      if (ids.length === 0) {
        this.appId = '';
        this.deployment = null;
        this.logs = [];
        this.rateLimited = false;
        this.checking = false;
        return;
      }
      this.appId = ids[0];
      this.rateLimited = false;
      this.checking = false;
      await this.refresh(true);
      this.startPoll();
    } catch (e) {
      this.showError(e as Error);
      this.checking = false;
    }
  }

  private showError(e: Error): void {
    const limited: boolean = e.message.indexOf('429') >= 0;
    this.rateLimited = limited;
    this.error = limited ? '' : deploymentErrorMessage(e);
  }

  private async refresh(includeLogs: boolean): Promise<void> {
    if (this.inFlight || this.appId.length === 0) {
      return;
    }
    this.inFlight = true;
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const id: string = this.appId;
    try {
      const next: PlatformDeployment = await getPlatformDeployment(ctx, id);
      this.deployment = next;
      if (includeLogs && !isTerminalDeployment(next.status)) {
        try {
          const lines: string[] = await getPlatformDeploymentLogs(ctx, id);
          if (lines.length > 0) {
            this.logs = lines;
          }
        } catch (e) {
          // 日志失败不打断状态轮询
        }
      }
      this.error = '';
      this.rateLimited = false;
      if (isTerminalDeployment(next.status)) {
        this.stopPoll();
      }
    } catch (e) {
      this.showError(e as Error);
    } finally {
      this.inFlight = false;
    }
  }

  private async createDeployment(): Promise<void> {
    if (this.creating) {
      return;
    }
    this.creating = true;
    this.error = '';
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      const id: string = await createPlatformDeployment(ctx);
      this.appId = id;
      const draft: PlatformDeployment = {
        appId: id, status: 'creating', accessUrl: '', errorMessage: '',
        message: '', progress: 0, versionType: ''
      };
      this.deployment = draft;
      this.logs = [];
      this.pollCount = 0;
      this.startPoll();
      await this.refresh(true);
    } catch (e) {
      this.showError(e as Error);
    } finally {
      this.creating = false;
    }
  }

  private confirmRestart(): void {
    if (this.appId.length === 0 || this.recovering) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: this.t($r('app.string.pd_confirm_restart_title')),
      message: this.t($r('app.string.pd_confirm_restart_msg')),
      primaryButton: {
        value: this.t($r('app.string.common_cancel')),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: this.t($r('app.string.pd_confirm_restart_action')),
        action: (): void => {
          this.doRestart();
        }
      }
    });
  }

  private async doRestart(): Promise<void> {
    const id: string = this.appId;
    if (id.length === 0) {
      return;
    }
    this.recovering = true;
    this.error = '';
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      await restartPlatformDeployment(ctx, id);
      this.markStatus('restarting', this.t($r('app.string.pd_restarting')));
      this.pollCount = 0;
      this.startPoll();
    } catch (e) {
      this.error = deploymentErrorMessage(e as Error);
    } finally {
      this.recovering = false;
    }
  }

  private confirmResetPair(): void {
    if (this.appId.length === 0 || this.resetting) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: this.t($r('app.string.pd_confirm_reset_title')),
      message: this.t($r('app.string.pd_confirm_reset_msg')),
      primaryButton: {
        value: this.t($r('app.string.common_cancel')),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: this.t($r('app.string.pd_confirm_reset_action')),
        action: (): void => {
          this.doResetPair();
        }
      }
    });
  }

  // 重置配对：reset-qwenpaw-auth + 重启一次（对齐 7378 resetQwenPawAuth）
  private async doResetPair(): Promise<void> {
    const id: string = this.appId;
    if (id.length === 0) {
      return;
    }
    this.resetting = true;
    this.error = '';
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      await resetPlatformQwenPawAuth(ctx, id);
      await restartPlatformDeployment(ctx, id);
      this.markStatus('starting', this.t($r('app.string.pd_restarting')));
      this.pollCount = 0;
      this.startPoll();
    } catch (e) {
      this.error = deploymentErrorMessage(e as Error);
    } finally {
      this.resetting = false;
    }
  }

  private confirmVersionSwitch(version: string): void {
    if (this.appId.length === 0 || this.switching.length > 0) {
      return;
    }
    const stable: boolean = version === 'stable';
    this.getUIContext().showAlertDialog({
      title: stable ? this.t($r('app.string.pd_confirm_switch_stable_title'))
        : this.t($r('app.string.pd_confirm_switch_beta_title')),
      message: this.t($r('app.string.pd_confirm_switch_msg')),
      primaryButton: {
        value: this.t($r('app.string.common_cancel')),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: stable ? this.t($r('app.string.pd_switch_stable')) : this.t($r('app.string.pd_switch_beta')),
        action: (): void => {
          this.doSwitchVersion(version);
        }
      }
    });
  }

  private async doSwitchVersion(version: string): Promise<void> {
    const id: string = this.appId;
    if (id.length === 0) {
      return;
    }
    this.switching = version;
    this.error = '';
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      await switchPlatformDeploymentVersion(ctx, id, version);
      this.markStatus('updating', version === 'stable'
        ? this.t($r('app.string.pd_switching_stable')) : this.t($r('app.string.pd_switching_beta')));
      this.pollCount = 0;
      this.startPoll();
    } catch (e) {
      this.error = deploymentErrorMessage(e as Error);
    } finally {
      this.switching = '';
    }
  }

  private markStatus(status: string, message: string): void {
    const current: PlatformDeployment | null = this.deployment;
    if (current === null) {
      return;
    }
    current.status = status;
    current.message = message;
    current.errorMessage = '';
    this.deployment = current;
  }

  // 打开 Platform 控制台（GitHub 绑定 / 资格申请等都在 Platform 侧完成）
  private openConsole(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ctx.startAbility({
      action: 'ohos.want.action.viewData',
      uri: `${PLATFORM_BASE_URL}/settings`
    }).catch((): void => {
      this.toast(`${PLATFORM_BASE_URL}/settings`);
    });
  }

  private async switchAccount(): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    await platformLogout(ctx);
    this.loggedIn = false;
    this.deployment = null;
    this.appId = '';
    this.logs = [];
  }

  private openLogin(): void {
    const stack: NavPathStack | null = this.stack;
    if (stack === null) {
      return;
    }
    const param: PlatformLoginParam = { returnTo: 'deploy', stack: stack };
    stack.pushPath({ name: 'platform-login', param: param });
  }

  private hasDeployment(): boolean {
    return this.appId.length > 0;
  }

  private statusPresentation(): DeploymentStatusPresentation {
    if (this.rateLimited) {
      return deploymentStatusPresentation('rate_limited');
    }
    if (this.creating) {
      return deploymentStatusPresentation('creating');
    }
    const d: PlatformDeployment | null = this.deployment;
    const p: DeploymentStatusPresentation =
      deploymentStatusPresentation(d !== null ? d.status : 'idle');
    if (d !== null && d.message.length > 0 && d.errorMessage.length === 0) {
      p.detail = d.message;
    }
    return p;
  }

  private deploymentFailure(): string {
    const d: PlatformDeployment | null = this.deployment;
    if (d !== null && d.status === 'failed' && d.errorMessage.length > 0) {
      return deploymentErrorMessage(new Error(d.errorMessage));
    }
    return '';
  }

  build() {
    HdsNavDestination() {
      Scroll() {
        Column() {
          if (!this.loggedIn && !this.checking) {
            this.hero(false)
            Text($r('app.string.pd_login_required'))
              .fontSize(UiTokens.fsBody)
              .fontColor($r('app.color.text_secondary'))
              .lineHeight(22)
              .width('100%')
              .margin({ top: 6 })
            this.primaryButton(0, $r('app.string.pd_login_action'), false, (): void => {
              this.openLogin();
            })
          } else {
            this.hero(this.hasDeployment())
            if (this.checking) {
              Row({ space: 10 }) {
                LoadingProgress().width(22).height(22).color(this.accent())
                Text($r('app.string.pd_checking'))
                  .fontSize(UiTokens.fsSecondary)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .padding(16)
              .borderRadius(UiTokens.cardRadius)
              .backgroundColor($r('app.color.card_glass'))
              .alignItems(VerticalAlign.Center)
            } else {
              this.statusCard()
              if (this.deployment !== null) {
                this.infoCard(this.deployment)
              }
              if (this.deployment !== null && this.deployment.status === 'running' &&
                !deploymentCompatibility(this.deployment.versionType).compatible) {
                this.mirrorCard(deploymentCompatibility(this.deployment.versionType))
              }
              if (this.hasDeployment()) {
                this.logCard()
              }
              if (this.error.length > 0) {
                Text(this.error)
                  .fontSize(UiTokens.fsSecondary)
                  .fontColor($r('app.color.status_error'))
                  .width('100%')
                  .lineHeight(19)
                  .margin({ top: 12 })
              } else if (this.deploymentFailure().length > 0) {
                Text(this.deploymentFailure())
                  .fontSize(UiTokens.fsSecondary)
                  .fontColor($r('app.color.status_error'))
                  .width('100%')
                  .lineHeight(19)
                  .margin({ top: 12 })
              }
              if (!this.hasDeployment() && !this.rateLimited) {
                this.primaryButton(1, $r('app.string.pd_deploy_now'), this.creating, (): void => {
                  this.createDeployment();
                })
              }
              if (this.hasDeployment()) {
                this.primaryButton(2, $r('app.string.pd_reset_pair'), this.resetting, (): void => {
                  this.confirmResetPair();
                })
              }
              if (this.hasDeployment()) {
                this.primaryButton(3, $r('app.string.pd_restart'), this.recovering, (): void => {
                  this.confirmRestart();
                })
              }
              this.ghostButton(4, $r('app.string.pd_recheck'), (): void => {
                if (this.hasDeployment()) {
                  this.refresh(true);
                } else {
                  this.check();
                }
              })
              this.ghostButton(5, $r('app.string.pd_open_console'), (): void => {
                this.openConsole();
              })
            }
            this.ghostButton(6, $r('app.string.pd_switch_account'), (): void => {
              this.switchAccount();
            })
            Text($r('app.string.pd_footer'))
              .fontSize(UiTokens.fsChip)
              .fontColor($r('app.color.text_tertiary'))
              .lineHeight(17)
              .width('100%')
              .margin({ top: 14, bottom: 24 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({
          top: UiTokens.topInset, left: UiTokens.pageHMargin, right: UiTokens.pageHMargin
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
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
        title: { mainTitle: $r('app.string.pd_title') }
      },
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: false
    })
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM],
      [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
    .onShown((): void => {
      // 从登录页返回：重新检查登录态与部署
      if (!this.loggedIn) {
        this.check();
      }
    })
  }

  @Builder
  hero(hasDeployment: boolean) {
    Column() {
      Column() {
        Image($r('app.media.cloud'))
          .width(25).height(25)
          .fillColor(Color.White)
      }
      .width(58)
      .height(58)
      .borderRadius(18)
      .backgroundColor(this.accent())
      .justifyContent(FlexAlign.Center)

      Text(hasDeployment
        ? $r('app.string.pd_hero_has') : $r('app.string.pd_hero_new'))
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary_strong'))
        .margin({ top: 16 })
      Text(hasDeployment
        ? $r('app.string.pd_hero_has_sub') : $r('app.string.pd_hero_new_sub'))
        .fontSize(UiTokens.fsBody)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(22)
        .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // 状态卡：状态标签 + 说明 + 三步进度（创建实例 → 启动服务 → 安全配对）
  @Builder
  statusCard() {
    Column() {
      Row() {
        Column() {
          Text(this.statusPresentation().label)
            .fontSize(UiTokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary_strong'))
          Text(this.statusPresentation().detail)
            .fontSize(UiTokens.fsSecondary)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(19)
            .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.statusPresentation().active || this.creating) {
          LoadingProgress().width(22).height(22).color(this.accent())
        } else if (this.statusPresentation().failed) {
          Image($r('app.media.refresh_cw'))
            .width(20).height(20)
            .fillColor($r('app.color.status_error'))
        } else if (this.hasDeployment()) {
          Image($r('app.media.check'))
            .width(21).height(21)
            .fillColor(this.accent())
        } else {
          Image($r('app.media.cloud'))
            .width(21).height(21)
            .fillColor(this.accent())
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row() {
        this.progressStep(1, $r('app.string.pd_step_create'))
        this.stepLine(1)
        this.progressStep(2, $r('app.string.pd_step_start'))
        this.stepLine(2)
        this.progressStep(3, $r('app.string.pd_step_pair'))
      }
      .width('100%')
      .margin({ top: 18 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(16)
    .borderRadius(UiTokens.cardRadius)
    .backgroundColor($r('app.color.card_glass'))
    .margin({ top: 16 })
  }

  private currentProgress(): number {
    return deploymentProgress(this.deployment !== null ? this.deployment.status : '', this.hasDeployment());
  }

  @Builder
  progressStep(index: number, label: Resource) {
    Column() {
      Text(index.toString())
        .fontSize(UiTokens.fsChip)
        .fontColor(this.currentProgress() >= index ? Color.White : $r('app.color.text_tertiary'))
        .textAlign(TextAlign.Center)
        .width(22)
        .height(22)
        .borderRadius(11)
        .backgroundColor(this.currentProgress() >= index
          ? this.accent() : $r('app.color.card_bg'))
      Text(label)
        .fontSize(10)
        .fontColor(this.currentProgress() >= index
          ? $r('app.color.text_secondary') : $r('app.color.text_tertiary'))
        .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  stepLine(index: number) {
    Row()
      .layoutWeight(1)
      .height(2)
      .margin({ left: 4, right: 4, bottom: 16 })
      .backgroundColor(this.currentProgress() > index
        ? this.accent() : $r('app.color.line'))
  }

  @Builder
  infoCard(d: PlatformDeployment) {
    IosGroup({ title: this.t($r('app.string.pd_instance')) }) {
      IosRow({ label: this.t($r('app.string.pd_app_id')), subtitle: d.appId, showIcon: false })
      IosRow({
        label: this.t($r('app.string.pd_access')),
        subtitle: d.accessUrl.length > 0 ? d.accessUrl : this.t($r('app.string.pd_access_pending')),
        showIcon: false
      })
      IosRow({
        label: this.t($r('app.string.pd_mirror')),
        subtitle: d.versionType.length > 0
          ? deploymentCompatibility(d.versionType).label : this.t($r('app.string.pd_mirror_unknown')),
        showIcon: false
      })
    }
  }

  @Builder
  mirrorCard(c: DeploymentCompatibility) {
    Column() {
      Text($r('app.string.pd_mirror_unsupported_title'))
        .fontSize(UiTokens.fsBody)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary_strong'))
        .width('100%')
      Text(`${this.t($r('app.string.pd_mirror_detected'))}${c.label}`)
        .fontSize(UiTokens.fsSecondary)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(19)
        .margin({ top: 4 })
        .width('100%')
      this.primaryButton(7, $r('app.string.pd_switch_stable'), this.switching === 'stable', (): void => {
        this.confirmVersionSwitch('stable');
      })
      this.ghostButton(8, $r('app.string.pd_switch_beta'), (): void => {
        this.confirmVersionSwitch('preview');
      })
    }
    .width('100%')
    .padding(16)
    .borderRadius(UiTokens.cardRadius)
    .backgroundColor($r('app.color.card_glass'))
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 12 })
  }

  @Builder
  logCard() {
    Column() {
      Row({ space: 7 }) {
        Image($r('app.media.file_text'))
          .width(17).height(17)
          .fillColor($r('app.color.status_warning'))
        Text($r('app.string.pd_log_title'))
          .fontSize(UiTokens.fsBody)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary_strong'))
        Text($r('app.string.pd_live'))
          .fontSize(10)
          .fontColor($r('app.color.status_success'))
          .margin({ left: 4 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column() {
        if (this.logs.length === 0) {
          Text(this.deployment !== null && this.deployment.message.length > 0
            ? this.deployment.message : this.t($r('app.string.pd_log_empty')))
            .fontSize(UiTokens.fsChip)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        } else {
          ForEach(this.tailLogs(), (line: string, idx: number) => {
            Text(line)
              .fontSize(UiTokens.fsChip)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .lineHeight(16)
              .margin({ bottom: 2 })
          }, (line: string, idx: number) => `${idx}|${line}`)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(12)
      .borderRadius(10)
      .backgroundColor($r('app.color.card_bg'))
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(14)
    .borderRadius(UiTokens.cardRadius)
    .backgroundColor($r('app.color.card_glass'))
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 12 })
  }

  // 只展示末尾 N 行（对齐 7378 logs.slice(-40)）
  private tailLogs(): string[] {
    if (this.logs.length <= LOG_LINES) {
      return this.logs;
    }
    return this.logs.slice(this.logs.length - LOG_LINES);
  }

  @Builder
  primaryButton(idx: number, label: Resource, busy: boolean, onTap: () => void) {
    Text(label)
      .fontSize(UiTokens.fsBody)
      .fontWeight(FontWeight.Medium)
      .fontColor(Color.White)
      .textAlign(TextAlign.Center)
      .width('100%')
      .height(48)
      .borderRadius(24)
      .backgroundColor(this.accent())
      .opacity(busy ? 0.6 : 1)
      .margin({ top: 16 })
      .scale({ x: this.pressed === idx ? PRESS_SCALE : 1, y: this.pressed === idx ? PRESS_SCALE : 1 })
      .visualEffect(pressEffect(this.pressed === idx))
      .onTouch((e: TouchEvent): void => {
        pressTouch(this.getUIContext(), e, this.latch, (v: boolean): void => {
          this.pressed = v ? idx : -1;
        });
      })
      .onClick((): void => {
        if (!busy) {
          onTap();
        }
      })
  }

  @Builder
  ghostButton(idx: number, label: Resource, onTap: () => void) {
    Text(label)
      .fontSize(UiTokens.fsBody)
      .fontColor($r('app.color.btn_gray_text'))
      .textAlign(TextAlign.Center)
      .width('100%')
      .height(44)
      .borderRadius(22)
      .backgroundColor($r('app.color.card_glass'))
      .margin({ top: 10 })
      .scale({ x: this.pressed === idx ? PRESS_SCALE : 1, y: this.pressed === idx ? PRESS_SCALE : 1 })
      .visualEffect(pressEffect(this.pressed === idx))
      .onTouch((e: TouchEvent): void => {
        pressTouch(this.getUIContext(), e, this.latch, (v: boolean): void => {
          this.pressed = v ? idx : -1;
        });
      })
      .onClick((): void => {
        onTap();
      })
  }
}
