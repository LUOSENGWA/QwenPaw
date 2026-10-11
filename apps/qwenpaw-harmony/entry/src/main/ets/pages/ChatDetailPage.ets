/*
 * 会话详情 —— 移植 PR #7378 apps/qwenpaw-mobile/app/chat/[id].tsx 一期形态：
 *   历史（GET /api/chats/{id}）+ 输入发送（POST /api/console/chat，stream:true）流式追加 + 停止当前轮。
 * 路由参数：{ chatId, chatName }（routerMap 名 chat，由「会话」tab 的会话行打开）。
 */

import {
  HdsNavDestination, ScrollEffectType, BlurStrategy, hdsMaterial,
  HdsNavigationMenuContentOptions, HdsNavigationMenuItemOptions
} from '@kit.UIDesignKit';
import { emitter } from '@kit.BasicServicesKit';
import { common, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import {
  uiMaterial,
  KeyboardAvoidMode,
  window,
  curves,
} from '@kit.ArkUI';
import { QpConnection, loadConnection } from '../services/ConnectionStore';
import { sessionApproval, setSessionApproval, takeLoopCommand, applyLoopCommand } from '../services/SessionControls';
import { PendingTurn, loadPendingTurn, savePendingTurn, clearPendingTurn } from '../services/PendingTurn';
import { fetchAgentApproval } from '../services/AgentApproval';
import { loadChatApproval } from '../services/ChatApprovalPrefs';
import {
  DisplayTurn, DisplayMessage, DisplayPart, ChatSnapshot, fetchChatMessages, streamChat, reconnectChat, stopChat,
  ChatStreamHandle, ChatInputPart, UploadResult, uploadAttachment, CHAT_CLOSED_EVENT,
  ResponseBlock, responseBlocks, textOfParts, partsTextLen,
  toolMediaParts, mergeMediaParts, turnFilesOf
} from '../services/ChatDetailService';
import { pickFiles, removeTemp, PickedFile } from '../services/AttachmentPicker';
import { StreamDelta } from '../services/SseParser';
import { ApprovalInfo, fetchApprovals, approveRequest, denyRequest } from '../services/ApprovalsService';
import { fetchChats, ChatInfo, pinChat, setChatArchived, deleteChat } from '../services/ChatsService';
import { ApprovalCard } from '../components/ApprovalCard';
import { SessionRuntimeBar } from '../components/SessionRuntimeBar';
import { ChatRow, ConversationRow, rowOf, rowHasVisibleContent, mergeToolMessages } from '../components/ChatRows';
import { ChatSkeleton } from '../components/ChatSkeleton';
import { areaWidthOf, wideClampW } from '../theme/Breakpoints';
import { ThemeManager, ThemeSnapshot, ThemeListener } from '../theme/ThemeManager';
import { UiTokens, pxPerVp } from '../theme/UiTokens';
import { blendHex } from '../theme/Accent';
import { PRESS_SCALE, PressLatch, pressEffect, pressTouch } from '../theme/PressFx';
import { slideCoverTransition } from '../services/NavPush';

@Builder
export function ChatDetailPageBuilder(_name: string, param: Object) {
  ChatDetailPage({ params: param })
}

// 过程组展开/收起、行插入/消失的补间时长（对齐 tab 切换的 240ms 档，卡片增删是"放大/缩小"而不是瞬跳）
const EXPAND_ANIM_MS: number = 220;
// 「一键回到底部」按钮：直径与出现/隐藏过渡（对齐 console 那套 0.2s 过渡）
const BOTTOM_FAB_SIZE: number = 36;
const BOTTOM_FAB_ANIM_MS: number = 200;
// 输入胶囊之上运行状态条的高度预留（SessionRuntimeBar 一行芯片）
const RUNTIME_ROW_RESERVE: number = 28;

// 待发附件（已上传成功，发送时转成 content 分片）
interface PendingAttachment {
  id: string;
  name: string;
  kind: string;     // image / video / audio / file
  url: string;
  fileName: string;
}

@Component
export struct ChatDetailPage {
  params: Object = new Object();
  @State chatId: string = '';
  @State chatName: string = '';
  // 置顶态（标题栏菜单用）：会话详情接口不回该字段，由会话列表里本会话那一项取得
  @State chatPinned: boolean = false;
  private stack: NavPathStack | null = null;
  // 二级页水平覆盖转场的位移（百分比）：由 NavPush.slideCoverTransition 驱动
  @State pageX: string = '0%';
  @State @Watch('onTurnsChanged') turns: DisplayTurn[] = [];
  // 过程组展开/收起：扁平化后组内行是页面 List 的独立项，因此「哪一组展开」必须由页面持有，
  // 而不能留在组卡组件内部。默认展开态 = 活动组展开、其余收起（见 rows()）；两个列表只记
  // 「用户手动改过」的组（互斥），用户在默认态之外的选择以用户为准。
  @State expandedGroups: string[] = [];
  @State collapsedGroups: string[] = [];
  // 各过程组的默认展开态（键 → 是否活动组），rows() 每次重建写回；组头点击据此判断当前态
  private groupGen: Map<string, boolean> = new Map<string, boolean>();
  // 在途回合的行对象（键 → 实例）：流式期间复用同一实例并就地赋新值，行组件经 @ObjectLink
  // 原地更新（不重建子树、不闪屏）；回合落定后由 rows() 逐键覆盖为新实例，此处旧实例自然弃用
  private liveRows: Map<string, ConversationRow> = new Map<string, ConversationRow>();
  @State draft: string = '';
  @State sending: boolean = false;
  @State attachments: PendingAttachment[] = [];   // 已上传待发送的附件
  // 本会话待审批（对齐 RN chat/[id].tsx：root_session_id === chat.session_id || chat.id）
  @State approvals: ApprovalInfo[] = [];
  @State uploading: boolean = false;              // 附件上传中（按钮转圈）
  @State errorMsg: string = '';
  @State isDark: boolean = false;
  @State theme: ThemeSnapshot = ThemeManager.get().snapshot();
  // 发送/停止按钮的按压态：0=发送 1=停止，-1=无（内容区材质不生效 → 按压反馈用通用属性自绘）
  @State btnPressed: number = -1;
  private btnLatch: PressLatch = new PressLatch();
  private scroller: Scroller = new Scroller();
  private stream: ChatStreamHandle | null = null;
  // 发送用的 session_id（对齐 RN store：sessionId = chat.session_id，与 chatId 可能不同）
  private sessionId: string = '';
  // 该会话归属的 user_id（详情响应带出；服务端按 (session_id, user_id) 定位 chat）
  private userId: string = '';
  // 在途回合的本地记录（对齐 7378 pendingChat：切走/重挂载后自己那条不丢）
  private pending: PendingTurn | null = null;
  // 当前流式增量要并入的回合 id：发送时指向本地回显回合，快照出现同一条用户消息后改指
  // 服务端那条回合（服务端回合 id 与本地 turn_<ts> 不同，故不能只认 id，须按用户文本对接）
  private liveTurnId: string = '';
  private pollTimer: number = -1;

  // 本会话待审批：按 root_session_id 归属过滤（与 RN 同口径）
  private async refreshApprovals(): Promise<void> {
    if (this.conn === null) {
      return;
    }
    try {
      const conn: QpConnection = this.conn;
      const all: ApprovalInfo[] = await fetchApprovals(conn.baseUrl, conn.token, conn.agentId);
      const sid: string = this.sessionId.length > 0 ? this.sessionId : this.chatId;
      this.approvals = all.filter((a: ApprovalInfo): boolean =>
        a.rootSessionId === sid || a.rootSessionId === this.chatId);
    } catch (e) {
      // 静默：不影响聊天
    }
  }

  // 批准（exact/similar）/ 拒绝，成功后本地移除（对齐 RN approve/deny）
  private async actApproval(item: ApprovalInfo, scope: string, deny: boolean): Promise<void> {
    if (this.conn === null) {
      return;
    }
    const conn: QpConnection = this.conn;
    try {
      if (deny) {
        await denyRequest(conn.baseUrl, conn.token, conn.agentId, item.requestId, item.rootSessionId,
          'User denied');
      } else {
        await approveRequest(conn.baseUrl, conn.token, conn.agentId, item.requestId, item.rootSessionId,
          scope);
      }
      this.approvals = this.approvals.filter((a: ApprovalInfo): boolean => a.requestId !== item.requestId);
    } catch (e) {
      this.errorMsg = this.t($r('app.string.approval_failed'));
    }
  }
  private conn: QpConnection | null = null;
  private themeListener: ThemeListener | null = null;

  // 发送(0)/停止(1)按钮按压：缩放动画与点光源由 pressTouch/pressEffect 统一驱动
  private canSend(): boolean {
    return this.draft.trim().length > 0;
  }

  // 键盘避让模式：本页必须用 OFFSET（页面整体上移）。用 RESIZE 时页面被压缩，
  // 悬浮页签栏（输入条）会被压扁并贴到键盘上沿，观感"键盘遮挡输入框"。
  private prevKeyboardAvoidMode: KeyboardAvoidMode | null = null;
  // 键盘高度（vp）：避让模式设 NONE 后页面不再被压缩/上抬，改由本页按此值让出底部，
  // 否则悬浮输入条会被键盘盖住（RESIZE 下则是被压扁贴在键盘上沿）。
  @State keyboardInset: number = 0;
  private kbWindow: window.Window | null = null;
  private kbListener: ((data: window.AvoidAreaOptions) => void) | null = null;

  private onBtnTouch(idx: number, e: TouchEvent): void {
    pressTouch(this.getUIContext(), e, this.btnLatch, (v: boolean): void => {
      this.btnPressed = v ? idx : -1;
    });
  }

  // 输入条内容（挂在 Tabs 悬浮页签栏内）：材质、弹性形变、纯圆两端都由
  // barFloatingStyle.systemMaterial 提供，故控件一律透明底，让材质层透出。
  // 会话运行状态条**不在**输入胶囊里：capsule 只包输入行，状态条浮在胶囊之上
  // （见下方 runtimeRow + Tabs.overlay，官方《Tabs 使用 overlay 在页签栏添加自定义组件》写法）。
  // 会话运行状态条（浮在输入胶囊之上）：宽度与胶囊对齐（左右各留 pageHMargin）；
  // hitTestBehavior(Transparent) 让浮层空白处不阻挡下方消息列表滚动（官方 FAQ 明示）
  @Builder
  runtimeRow() {
    Row() {
      SessionRuntimeBar({
        chatId: this.chatId,
        sessionId: this.sessionId
      })
    }
    .width('100%')
    .height('100%')
    // 浮层容器是整个 Tabs 尺寸 → 内容必须显式底对齐，行底即胶囊顶上方 3vp
    .alignItems(VerticalAlign.Bottom)
    .padding({ left: UiTokens.pageHMargin, right: UiTokens.pageHMargin })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  composerBar() {
    Column() {
        Row() {
          Button() {
            if (this.uploading) {
              LoadingProgress()
                .width(20)
                .height(20)
                .color(this.isDark ? this.theme.accentDark : this.theme.accent)
            } else {
              // 附件图标用 QwenPaw 自己的 design 资产（creator 的 HeroComposerCard 同款
              // icon-add-file.svg）；源 SVG 深色填充在暗色主题下不可见 → fillColor 上色
              Image($r('app.media.icon_add_file'))
                .width(20)
                .height(20)
                .fillColor($r('app.color.btn_gray_text'))
                .draggable(false)
            }
          }
          .type(ButtonType.Normal)
          .width(40)
          .height(40)
          .padding(0)
          // 同上：透明底，避免在材质层上再压一块实底
          .backgroundColor(Color.Transparent)
          .borderWidth(1)
          .borderColor(this.isDark ? '#3DFFFFFF' : '#4D000000')
          .borderRadius(20)
          .enabled(!this.uploading)
          .scale({ x: this.btnPressed === 2 ? PRESS_SCALE : 1, y: this.btnPressed === 2 ? PRESS_SCALE : 1 })
          .stateEffect(false)
          .visualEffect(pressEffect(this.btnPressed === 2))
          .onTouch((e: TouchEvent): void => {
            this.onBtnTouch(2, e);
          })
          .onClick((): void => {
            this.attach();
          })
          .margin({ right: 8 })

          TextInput({ text: $$this.draft, placeholder: $r('app.string.chat_input_placeholder') })
            .layoutWeight(1)
            .height(42)
            .fontSize(UiTokens.fsBody)
            // 透明：让胶囊的材质层（磨砂 + 受光渐层）连续透出，而不是被一层实底盖住
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.input_text'))
            .placeholderColor($r('app.color.placeholder'))
            .borderRadius(21)
            .enterKeyType(EnterKeyType.Send)
            .onSubmit((): void => {
              this.send();
            })
          if (this.sending) {
            Button($r('app.string.chat_stop'))
              .height(42)
              .margin({ left: 8 })
              // 玻璃底（内容区材质不生效，官方 FAQ 范围规则）
              .backgroundColor($r('app.color.card_glass'))
              .fontColor($r('app.color.status_error'))
              .scale({ x: this.btnPressed === 1 ? PRESS_SCALE : 1, y: this.btnPressed === 1 ? PRESS_SCALE : 1 })
              .stateEffect(false)
              .visualEffect(pressEffect(this.btnPressed === 1))
              .onTouch((e: TouchEvent): void => {
                this.onBtnTouch(1, e);
              })
              .onClick((): void => {
                this.stop();
              })
          } else {
            Button($r('app.string.chat_send'))
              .height(42)
              .margin({ left: 8 })
              // 实底按钮一律**不透明**：不用 enabled(false)（框架禁用态压到约 48%，实测 (57,82,122)），
              // 也不用 opacity（alpha 会被底衬影响、观感发虚）——弱化态用不透明混色表达；
              // 另显式关掉沉浸材质（官方组件级关闭开关 uiMaterial.Material.empty），避免材质层盖在实底上
              .backgroundColor(this.canSend()
                ? (this.isDark ? this.theme.accentDark : this.theme.accent)
                : blendHex(this.isDark ? this.theme.accentDark : this.theme.accent, '#000000', 0.55))
              .systemMaterial(uiMaterial.Material.empty)
              .fontColor(Color.White)
              .scale({ x: this.btnPressed === 0 ? PRESS_SCALE : 1, y: this.btnPressed === 0 ? PRESS_SCALE : 1 })
              .stateEffect(false)
              .visualEffect(pressEffect(this.btnPressed === 0))
              .onTouch((e: TouchEvent): void => {
                this.onBtnTouch(0, e);
              })
              .onClick((): void => {
                if (this.canSend()) {
                  this.send();
                }
              })
          }
        }
        .width('100%')
        // 竖直方向不留内边距、高度交给栏体内容区（实测悬浮栏本体 203px、内容区 175px）：
        // 写死 58 + 上下各 8 内边距需要 203px > 内容区 175px → 行被压扁、内容贴底
        // 表现为"按钮没有垂直居中"。
        .padding({ left: 3, right: 3 })
        .alignItems(VerticalAlign.Center)
        .height(UiTokens.chatComposerBarInner)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  // 大屏（平板/电脑）正文列限宽：官方《页面布局场景》缩进布局 —— 正文列居中、两侧留白；
  // 分栏态下本页位于右栏（本就窄），此限宽只对超宽窗口（PC）生效；实现见 theme/Breakpoints
  @State pageW: number = 0;

  private onChatArea = (_old: Area, now: Area): void => {
    this.pageW = areaWidthOf(now, this.pageW);
  };

  aboutToAppear(): void {
    const rec: Record<string, Object> = this.params as Record<string, Object>;
    const id: Object = rec['chatId'];
    const name: Object = rec['chatName'];
    this.chatId = typeof id === 'string' ? id as string : '';
    this.chatName = typeof name === 'string' ? name as string : '';
    const sid: Object = rec['sessionId'];
    this.sessionId = typeof sid === 'string' && (sid as string).length > 0 ? sid as string : this.chatId;
    const uid: Object = rec['userId'];
    this.userId = typeof uid === 'string' ? uid as string : '';
    this.prevKeyboardAvoidMode = this.getUIContext().getKeyboardAvoidMode();
    window.getLastWindow(getContext(this)).then((w: window.Window): void => {
      this.kbWindow = w;
      const cb = (data: window.AvoidAreaOptions): void => {
        if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) {
          const inset: number = data.area.bottomRect.height / pxPerVp();
          // 显式动画（官方 animateTo）：本身直接改 padding 是瞬跳，键盘弹起/收起会"啪"一下；
          // 这里给布局变化插入过渡，恢复与框架避让同感的起落动画。
          // 弹簧曲线（springMotion）比时长曲线更有"弹"感；用弹簧时 duration 不生效，
          // 节奏由 response/dampingFraction 决定（响应越快越跟手，阻尼越小回弹越明显）。
          this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.68) }, (): void => {
            this.keyboardInset = inset;
          });
        }
      };
      this.kbListener = cb;
      w.on('avoidAreaChange', cb);
    });
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.isDark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.themeListener = (snap: ThemeSnapshot): void => {
      this.theme = snap;
    };
    ThemeManager.get().subscribe(this.themeListener);
    ThemeManager.get().load(ctx).then((): void => {
      this.theme = ThemeManager.get().snapshot();
    });
    this.loadHistory();
    // 与 Console 保持同步（对齐 RN chat/[id].tsx 的 useFocusEffect + setInterval 轮询）：
    // 定时静默重取历史，Console 侧新消息也能进来；流式进行中不打扰
    this.pollTimer = setInterval((): void => {
      this.refreshApprovals();
      this.refreshHistory();
    }, 2500);
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
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    if (this.themeListener !== null) {
      ThemeManager.get().unsubscribe(this.themeListener);
      this.themeListener = null;
    }
    if (this.stream !== null) {
      this.stream.stop();
      this.stream = null;
    }
    emitter.emit(CHAT_CLOSED_EVENT);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.isDark = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  // 在途记录（落盘）读取：只在进页面时读一次（重启/重新进页面后靠它把"自己那条"接回来）
  private async loadPendingRecord(): Promise<PendingTurn | null> {
    const conn: QpConnection | null = this.conn;
    if (conn === null) {
      return null;
    }
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return await loadPendingTurn(ctx, conn.baseUrl, conn.agentId, this.chatId);
  }

  // 发送用的审批等级落定：模块级单例是全局的，页面上叠了别的会话页再退回本页时，单例可能还停在
  // 上一页的值（会被带进本页的发送）。本页每次进页面/回到前台都按**本会话生效值**重设一次：
  // 本会话覆盖（本机，见 ChatApprovalPrefs）优先，没有则用服务端 Agent 级 approval_level。
  private async applySessionApproval(): Promise<void> {
    const conn: QpConnection | null = this.conn;
    if (conn === null) {
      return;
    }
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const override: string = await loadChatApproval(ctx, conn.baseUrl, conn.agentId, this.chatId);
      setSessionApproval(override.length > 0 ? override
        : await fetchAgentApproval(conn.baseUrl, conn.token, conn.agentId));
    } catch (e) {
      setSessionApproval('');
    }
  }

  private dropPendingRecord(): void {
    const c: QpConnection | null = this.conn;
    if (c === null) {
      return;
    }
    clearPendingTurn(getContext(this) as common.UIAbilityContext, c.baseUrl, c.agentId, this.chatId);
  }

  private turnById(id: string): DisplayTurn | null {
    for (const t of this.turns) {
      if (t.id === id) {
        return t;
      }
    }
    return null;
  }

  // 服务端快照里是否已有这条用户消息（返回其回合下标，-1 = 还没有）。
  // 判据只认服务端下发的列表：不能用"本地列表最后一条用户消息"来判断——
  // 本地那条回显文本就是它自己，用本地列表判断会把自己判成"服务端已收到"而提前退役。
  private serverEchoIndex(list: DisplayTurn[], text: string): number {
    for (let i = list.length - 1; i >= 0; i--) {
      const u: DisplayMessage | null = list[i].user;
      if (u !== null && textOfParts(u.parts) === text) {
        return i;
      }
    }
    return -1;
  }

  // 服务端快照落地的唯一出口（轮询 / 重取 / 进页面三条路径共用）。取数是异步的，
  // 「取数在途期间用户刚好按下发送」这段窗口里落地的快照若直接替换 turns，会把本地回显整条抹掉
  // （真机实测：长会话一次取数近 1s，命中窗口不小；表现为"看不到自己刚发的那条，等这轮跑完才出现"）。
  //   ① 服务端已收下这条 → 回显退役（流式增量改并入服务端那条回合），落盘的在途记录作废；
  //   ② 服务端还没有 → 保留本地在途回合接在快照末尾（自己发的那条绝不丢；没有本地回合时按记录重建）。
  private settleSnapshot(list: DisplayTurn[], rec: PendingTurn | null): DisplayTurn[] {
    if (rec === null) {
      return list;
    }
    const at: number = this.serverEchoIndex(list, rec.text);
    if (at >= 0) {
      this.liveTurnId = list[at].id;
      this.pending = null;
      this.dropPendingRecord();
      return list;
    }
    const found: DisplayTurn | null = this.turnById(rec.turnId);
    const echo: DisplayTurn = found !== null ? found : this.echoTurnOf(rec);
    this.liveTurnId = echo.id;
    this.pending = rec;
    // 快照尾部常带一条「无用户消息的在途回合」（服务端对同一次运行的视图）：它与本地回显
    // 是同一条 run 的两份视图，同时挂上会重复渲染，故以本地那份为准，去掉快照尾部的裸回合。
    const arr: DisplayTurn[] = list.slice();
    while (arr.length > 0 && arr[arr.length - 1].user === null) {
      arr.pop();
    }
    arr.push(echo);
    return arr;
  }

  // 按在途记录重建本地回显回合（记录里只留了文本与回合 id，重启/重新进页面时照它还原）
  private echoTurnOf(rec: PendingTurn): DisplayTurn {
    const up: DisplayPart = { type: 'text', text: rec.text };
    const um: DisplayMessage = { id: `u_${rec.turnId}`, role: 'user', kind: 'message', parts: [up] };
    return { id: rec.turnId, user: um, responses: [], pending: true };
  }

  // 会话展平成行序列（一行 = 一个 ListItem 的载荷）。顺序：用户气泡 → 响应分段（消息段 / 步骤组）
  // → 待发占位（仅当该回合还没出可见文本）→ 该回合工具产出媒体。
  // 行对象复用规则：在途回合的行复用同一实例（行组件用 @ObjectLink 观察它 ⇒ 流式期间原地更新，
  // 不重建子树）；已完结回合的行每次新建，没有观察者、不产生无谓刷新。
  private rows(): ConversationRow[] {
    const out: ConversationRow[] = [];
    for (const turn of this.turns) {
      const tid: string = turn.id;
      if (turn.user !== null) {
        const u: DisplayMessage = turn.user;
        out.push(this.rowFor(`u:${tid}`, 'user', tid, turn.pending, [u], [], false, false, false));
      }
      // 响应按 console 口径分段（responseBlocks，语义不改）：message 段逐段可见、其余收进 steps 组
      const blocks: ResponseBlock[] = responseBlocks(turn.responses, turn.pending);
      // 活动组 = 最后一个步骤组（对齐 console HostBubbles：默认展示口径下
      // statusStepBlockIndex = findLastStepBlockIndex(messageBlocks)，即只认"最后一个步骤组"，
      // 其后即使还跟了文本段也仍是它）：只有活动组处于「生成中」，其状态文案与转圈随生成推进；
      // 其余组一律视为已完成（getCollapsedGroupStatus：非活动组 → Completed）。
      let activeStep: number = -1;
      if (turn.pending) {
        for (let i = blocks.length - 1; i >= 0; i--) {
          if (blocks[i].kind === 'steps') {
            activeStep = i;
            break;
          }
        }
      }
      for (let i = 0; i < blocks.length; i++) {
        const b: ResponseBlock = blocks[i];
        // 键 = 回合 + 块序号（结构键，不含内容指纹）：内容变化靠行对象原地更新，键变化即重建子树
        if (b.kind === 'message') {
          if (!messagesHaveContent(b.messages)) {
            continue;   // 空响应段（无可见文本 / 无媒体 / 无错误）不出行，否则渲染成一张空白气泡卡
          }
          out.push(this.rowFor(`m:${tid}:${i}`, 'message', tid, turn.pending, b.messages, [],
            !turn.pending, false, false));
        } else {
          // 过程组 = 组头一条 +（展开时）组内每行各一条独立列表项：
          // 一行一个 ListItem 才能吃到 List 的虚拟化（此前整组一个 item，数百行一次性构建）
          const gk: string = `${tid}:${i}`;
          const gen: boolean = i === activeStep;
          // 默认展开态对齐 console getCollapsedStepPresentation（生成中 → defaultOpen = true，其余 false）：
          // 活动组默认展开、已完成的组默认收起；用户手动开合过的那一组以用户选择为准。
          // 默认态另记一份到 groupGen（组头点击时按它判断"点的是收起还是展开"，
          // 已完结回合的行不在 liveRows 里，不能从行对象读）。
          this.groupGen.set(gk, gen);
          const expanded: boolean = this.expandedGroups.indexOf(gk) >= 0 ? true
            : (this.collapsedGroups.indexOf(gk) >= 0 ? false : gen);
          const head: ConversationRow = this.rowFor(`sh:${gk}`, 'stepsHeader', tid, turn.pending,
            b.messages, [], false, gen, false);
          head.expanded = expanded;
          head.groupKey = gk;
          out.push(head);
          if (expanded) {
            const procs: DisplayMessage[] = mergeToolMessages(b.messages);
            for (let pi = 0; pi < procs.length; pi++) {
              out.push(this.rowFor(`pr:${gk}:${pi}`, 'proc', tid, turn.pending, [procs[pi]], [],
                pi === procs.length - 1, gen, false));
            }
          }
        }
      }
      if (turn.pending && !this.turnHasStreamText(turn)) {
        out.push(this.rowFor(`p:${tid}`, 'pending', tid, true, [], [], false, false, false));
      }
      // 回合文件清单挂在末尾：工具产出的文件（按 file_path 取，含相对路径与任意扩展名）+
      // 工具媒体分片（截图等），对齐 console 的 ResponseArtifactList
      const media: DisplayPart[] = turnFilesOf(turn.responses);
      if (media.length > 0) {
        out.push(this.rowFor(`x:${tid}`, 'media', tid, false, [], media, false, false, false));
      }
    }
    return out;
  }

  // 取该键的行对象：在途回合复用同一实例并就地赋新值；已完结回合每次新建
  private rowFor(key: string, kind: string, turnId: string, pending: boolean,
    messages: DisplayMessage[], parts: DisplayPart[], last: boolean, generating: boolean,
    expanded: boolean): ConversationRow {
    let r: ConversationRow | undefined = this.liveRows.get(key);
    if (r === undefined) {
      r = rowOf(kind, key, turnId, messages, parts);
      if (pending) {
        this.liveRows.set(key, r);
      }
    }
    r.kind = kind;
    r.turnId = turnId;
    r.messages = messages;
    r.parts = parts;
    r.pending = pending;
    r.last = last;
    r.generating = generating;
    r.expanded = expanded;
    return r;
  }

  // 过程组展开/收起切换（组头点击）：包在显式动画里，展开/收起是"放大/缩小"而不是瞬跳。
  // 当前实际展开态 = 用户覆盖（优先）> 默认态（活动组展开）；据此把该组记进互斥的
  // expandedGroups / collapsedGroups（用户选择覆盖默认态，对齐 console LazyAccordion 受控手风琴）。
  private toggleSteps(gk: string): void {
    const open: string[] = this.expandedGroups.slice();
    const closed: string[] = this.collapsedGroups.slice();
    const isOpen: boolean = this.expandedGroups.indexOf(gk) >= 0 ? true
      : (this.collapsedGroups.indexOf(gk) >= 0 ? false : this.groupGen.get(gk) === true);
    if (isOpen) {
      const a: number = open.indexOf(gk);
      if (a >= 0) {
        open.splice(a, 1);
      }
      if (closed.indexOf(gk) < 0) {
        closed.push(gk);
      }
    } else {
      const b: number = closed.indexOf(gk);
      if (b >= 0) {
        closed.splice(b, 1);
      }
      if (open.indexOf(gk) < 0) {
        open.push(gk);
      }
    }
    this.getUIContext().animateTo({ duration: EXPAND_ANIM_MS, curve: Curve.EaseInOut }, (): void => {
      this.expandedGroups = open;
      this.collapsedGroups = closed;
    });
  }

  // 全部行（都进 ForEach，键稳定 ⇒ 不重建）。为什么不再把末行放在 ForEach 之外：新增响应段时，
  // "原来在外的末行"会移进 ForEach —— 对 ArkUI 而言是**销毁 + 重建**，那一行会闪一下（有过渡动画
  // 时更明显）。行数据经 @Observed/@ObjectLink 原地更新，键不变即不重建 subtree，故放在 ForEach 内
  // 同样能逐字刷新，且不会再出现"末行换位置"的重建。
  private allRows(): ConversationRow[] {
    return this.rows();
  }

  // 该回合是否已有可见的流式文本段（没有则出「正在生成」占位）
  private turnHasStreamText(turn: DisplayTurn): boolean {
    for (const m of turn.responses) {
      if (m.role === 'assistant' && m.kind === 'message' && textOfParts(m.parts).length > 0) {
        return true;
      }
    }
    return false;
  }

  // 历史摘要：只反映内容（文本长度与过程条目数）；消息身份已是内容派生，同内容必同摘要
  private turnsDigest(list: DisplayTurn[]): string {
    const parts: string[] = list.map((t: DisplayTurn): string => {
      let n: number = 0;
      for (const m of t.responses) {
        n += partsTextLen(m.parts);
      }
      return `${partsTextLen(t.user !== null ? t.user.parts : [])}:${n}:${t.responses.length}`;
    });
    return parts.join('|');
  }

  // 静默轻查（与审批同拍 2.5s）：① 服务端已 running 而本页没挂流（例如从 Console 发起的 run）
  // → 补挂 reconnect 流，这是"别处跑起来本页也能实时看到"的关键；② 内容确有变化才替换
  // （差异化判断，避免无谓重建；不强制滚到底，避免拽走阅读位置）。
  private async refreshHistory(): Promise<void> {
    if (this.sending || this.conn === null) {
      return;
    }
    try {
      const conn: QpConnection = this.conn;
      const snap: ChatSnapshot = await fetchChatMessages(conn.baseUrl, conn.token, conn.agentId,
        this.chatId);
      // 取数期间用户按了发送/挂上了流：这份快照的尾部已过时（缺刚发的那条），丢弃本次对齐，
      // 由下一拍或流结束时的重取接手（守卫只写在取数之前会漏掉这段窗口）
      if (this.sending || this.stream !== null) {
        return;
      }
      if (snap.running && this.stream === null) {
        this.attachRunningStream();
        return;
      }
      const next: DisplayTurn[] = this.settleSnapshot(snap.turns, this.pending);
      if (this.turnsDigest(next) !== this.turnsDigest(this.turns)) {
        this.turns = next;
      }
    } catch (e) {
      // 静默刷新失败不影响页面
    }
  }

  // 强制重取历史（流式结束 / 停止后调用）：对齐 RN store.send 的 finally → loadChat(chat.id)
  // 全量重取——reasoning/tool 块靠重取呈现（流式 delta 只打 message 进 answer 气泡）。
  private async reloadTurns(): Promise<void> {
    if (this.conn === null) {
      return;
    }
    try {
      const conn: QpConnection = this.conn;
      const snap: ChatSnapshot = await fetchChatMessages(conn.baseUrl, conn.token, conn.agentId,
        this.chatId);
      this.turns = this.settleSnapshot(snap.turns, this.pending);
      this.scrollBottom();
    } catch (e) {
      // 重取失败：保留本地流式内容，下一轮轮询再对齐
    }
  }

  // 重连进行中的会话流：与 send 同一套 delta 渲染与收尾（对齐 7378 store.reconnectChat）
  private attachRunningStream(): void {
    const conn: QpConnection | null = this.conn;
    if (conn === null || this.stream !== null) {
      return;
    }
    this.sending = true;
    // 重连的增量并入列表末尾那条在途回合（服务端在跑的这一次 run 就挂在它上面）
    this.liveTurnId = this.turns.length > 0 ? this.turns[this.turns.length - 1].id : '';
    this.stream = reconnectChat(conn.baseUrl, conn.token, conn.agentId,
      this.sessionId.length > 0 ? this.sessionId : this.chatId, this.userId,
      (delta: StreamDelta): void => {
        this.appendDelta(delta);
      },
      (error: string | null): void => {
        this.sending = false;
        this.stream = null;
        if (error !== null) {
          this.errorMsg = error;
        }
        this.reloadTurns();
      });
  }

  private async loadHistory(): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.historyDone = false;
    this.listSettled = false;
    this.listShown = false;
    this.armSettleCap();
    this.errorMsg = '';
    try {
      const conn: QpConnection | null = await loadConnection(ctx);
      if (conn === null) {
        this.errorMsg = this.t($r('app.string.chat_no_conn'));
        return;
      }
      this.conn = conn;
      this.applySessionApproval();
      this.refreshApprovals();
      this.loadChatMeta(conn);
      const snap: ChatSnapshot = await fetchChatMessages(conn.baseUrl, conn.token, conn.agentId,
        this.chatId);
      // 在途回显（自己发出去、服务端还没收下的那条）按落盘记录对齐：
      // 服务端已有 → 退役；还没有 → 接在快照末尾（进页面/重进都靠这一步不丢）
      this.pending = await this.loadPendingRecord();
      // 身份优先取列表项带来的 user_id（详情接口不返回该字段）；详情里若有则以它为准
      if (snap.userId.length > 0) {
        this.userId = snap.userId;
      }
      this.turns = this.settleSnapshot(snap.turns, this.pending);
      this.stickBottom = true;
      if (this.listShown) {
        this.landAtBottom();
      }
      if (snap.running) {
        // 服务端上一轮仍在跑（本机离开后回来 / 从 Console 发起）：重连该流实时呈现剩余内容
        // （对齐 7378 app/chat/[id].tsx：loadChat 回 running 时调用 reconnectChat）
        this.errorMsg = '';
        this.attachRunningStream();
      }
      this.scrollBottom();
    } catch (e) {
      this.errorMsg = (e as Error).message;
    }
    this.historyDone = true;
    this.onTurnsChanged();
  }

  private t(res: Resource): string {
    try {
      const host: common.Context = this.getUIContext().getHostContext() as common.Context;
      return host.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  // 是否贴着底部（由列表可见区间推断：末项可见即视为在底部）
  // 贴底跟随：新内容进来只在这个开关打开时把视图钉到底部；用户一旦自己划走就关掉
  //（松手时用 Scroller.isAtEnd 判定，划回底部自动恢复跟随）。
  // 历史是否已到位：未到位只显示转圈（空屏），到位后列表才成形（并带 initialIndex 直接落在底部）
  @State historyDone: boolean = false;
  // 列表已落定：内容仍在分批到达时不呈现，避免追加以"突然冒出来"的形式进入可视区
  @State listSettled: boolean = false;
  // 列表是否已首次呈现过：骨架屏只服务于"首次呈现之前"，呈现过就不再回退
  //（否则后续 turns 变化会把 listSettled 复位 → 又退回骨架屏 → 骨架/列表闪烁）
  @State listShown: boolean = false;
  private settleTimer: number = -1;
  private settleCapTimer: number = -1;

  // 状态变化的唯一出口（ArkUI 状态钩子）：每次 turns 被写入都重置 220ms 静默窗口，
  // 连续无变化才把骨架屏换成真实列表。实测进页面后行数会在 done 之后继续分批追加
  //（5→15→27→41，约 250ms 内），先落定再呈现可消除该批追加造成的闪现。
  private onTurnsChanged(): void {
    if (!this.historyDone) {
      return;
    }
    this.listSettled = false;
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
    }
    this.settleTimer = setTimeout((): void => {
      this.settleTimer = -1;
      this.listSettled = true;
      this.listShown = true;
      this.landAtBottom();
    }, 220);
  }

  // 上限兜底：活跃流式会话会持续变化，静默窗口可能迟迟不到 → 1.2s 后强制落定
  private armSettleCap(): void {
    if (this.settleCapTimer >= 0) {
      clearTimeout(this.settleCapTimer);
    }
    this.settleCapTimer = setTimeout((): void => {
      this.settleCapTimer = -1;
      this.listSettled = true;
      this.listShown = true;
      this.landAtBottom();
    }, 1200);
  }
  private stickBottom: boolean = true;
  // 列表是否停在末尾（控制「一键回到底部」按钮的进出场）；初值 true = 刚进来就是底部
  @State atBottom: boolean = true;
  // 手指是否正按在列表上：程序化 scrollEdge 不产生触摸事件，故用触摸态区分来源，
  // 不用时间型守卫（上轮的时间守卫在流式期间几乎常开 → 用户拖动被一直忽略 → 又被拽回底部）
  private userTouching: boolean = false;

  private scrollBottom(force: boolean = false): void {
    // 手指在列表上就绝不自动贴底（无论是否 force）：这是"上滑被拽回底部"的直接原因
    if (this.userTouching) {
      return;
    }
    if (!force && !this.stickBottom) {
      return;
    }
    setTimeout((): void => {
      this.scroller.scrollEdge(Edge.Bottom);
      this.syncBottomFab();
    }, 40);
  }

  // 开页面时把视口钉到底部。为什么要显式钉：List 的 initialIndex 只在**列表创建那一刻**生效，
  // 而长会话历史是分批到达的（解析慢时 1.2s 兜底会先放行列表）——数据后到就停在列表顶部，
  // 观感即"打开聊天页停在最上面"。列表首次呈现与历史落定两条路径各补一次到底。
  private landAtBottom(): void {
    this.stickBottom = true;
    setTimeout((): void => {
      this.scroller.scrollEdge(Edge.Bottom);
      this.syncBottomFab();
    }, 60);
  }

  // 「一键回到底部」按钮（对齐 console 用的 SDK 里的 BubbleList/ScrollToBottom）：
  // 判据 = 滚动位置是否真的在末尾（Scroller.isAtEnd），与 console 的"距底 >10px 才出现"同义；
  // 点击后平滑回到底并隐藏；出现/隐藏是 200ms 位移 + 透明度过渡（隐藏时下移自身高度、且不接收点击）。
  private syncBottomFab(): void {
    const atEnd: boolean = this.scroller.isAtEnd();
    if (atEnd !== this.atBottom) {
      this.atBottom = atEnd;
    }
  }

  private jumpToBottom(): void {
    // 回到底部同时恢复"跟随"（与划到底自动恢复同一口径）
    this.stickBottom = true;
    this.scroller.scrollToIndex(this.initialRowIndex(), true, ScrollAlign.END);
    this.syncBottomFab();
  }

  // 按钮底距：让开悬浮输入胶囊 + 其上方的运行状态条（两者高度见 UiTokens / runtimeRow）
  private bottomFabOffset(): number {
    return UiTokens.chatComposerBottomMargin + UiTokens.chatComposerHeight + 1
      + UiTokens.chatRuntimeRowGap + RUNTIME_ROW_RESERVE + 10;
  }

  // 列表初始落点 = 末尾留白项：List 创建即停在**最底部**（末条内容的底边贴着末尾留白，
  // 留白已含悬浮输入条 + 其上的运行状态条 ⇒ 末条不被遮挡）。不靠多次 scrollEdge 追底部。
  private initialRowIndex(): number {
    return this.allRows().length + 1;
  }

  // 流式增量归并（在 7378 基础上增强：message 实时进 answer；reasoning/tool 的流式文本
  // 亦实时累积进 process 对应消息，逐字呈现思考 / 工具文本，不再等流结束 reload）。
  // 归并进最后一个 turn（即发送时 push 的 live turn）。
  private pendingDeltas: StreamDelta[] = [];
  private deltaTimer: number = -1;

  // delta 先入缓冲，按 ~60ms 合并后再一次性落到 turns
  // （对齐 7378 store/app.ts 的 requestAnimationFrame 批量 flushText：逐 delta 重建会打爆渲染）
  private appendDelta(delta: StreamDelta): void {
    // 工具段的载荷在 toolName/Input/Output 上（text 为空），不能按文本长度提前丢弃
    const hasTool: boolean = delta.toolName !== undefined || delta.toolInput !== undefined
      || delta.toolOutput !== undefined || delta.toolState !== undefined;
    if (delta.text.length === 0 && !hasTool) {
      return;
    }
    this.pendingDeltas.push(delta);
    if (this.deltaTimer < 0) {
      this.deltaTimer = setTimeout((): void => {
        this.flushDeltas();
      }, 60);
    }
  }

  private flushDeltas(): void {
    this.deltaTimer = -1;
    const buf: StreamDelta[] = this.pendingDeltas;
    this.pendingDeltas = [];
    if (buf.length === 0) {
      return;
    }
    // 并入「当前在途回合」而不是「列表最后一条」：中间若有服务端快照落地（或尾部多出一条
    // 无用户消息的在途回合），按位置并入会把这一段响应挂到别的回合上去（真机实测会出现
    // 上一轮的内容里混进这一轮的思考/工具行）。在途回合由 liveTurnId 指明。
    const arr: DisplayTurn[] = this.turns.slice();
    let li: number = -1;
    if (this.liveTurnId.length > 0) {
      for (let i = arr.length - 1; i >= 0; i--) {
        if (arr[i].id === this.liveTurnId) {
          li = i;
          break;
        }
      }
    }
    if (li < 0 && this.sending && arr.length > 0) {
      li = arr.length - 1;
    }
    if (li < 0) {
      return;
    }
    let t: DisplayTurn = arr[li];
    for (const d of buf) {
      t = this.mergeDeltaInto(t, d);
    }
    arr[li] = t;
    // 这里**不能**用 animateTo 包住数据写入：同一帧里所有布局变化都会被补间 —— 不只是新插入的
    // 卡片，还包括正在流式增长的那块文本（高度持续变大）⇒ 整块一直在"呼吸"（观感即"一直在闪"）。
    // 卡片进场的淡入 / 上移改由行自身负责（ChatRow 的进场动画），与其它行的布局完全解耦。
    this.turns = arr;
    this.scrollBottom();
  }

  // 流式增量并入响应段（对齐 console：服务端每个 msg_id 就是一段，reasoning / plugin_call / message 各自成段）
  //   同一 msg_id = 该段续写；换了 msg_id = 新起一段（旧段原地保留，不再像早先那样把 answer 覆盖掉）。
  //   重连时服务端从头重放整条流，段按序重建，故不需要另做去重。
  private mergeDeltaInto(t: DisplayTurn, delta: StreamDelta): DisplayTurn {
    const res: DisplayMessage[] = t.responses.slice();
    let idx: number = -1;
    for (let i = res.length - 1; i >= 0; i--) {
      if (res[i].id === delta.messageId && delta.messageId.length > 0) {
        idx = i;
        break;
      }
    }
    const hasTool: boolean = delta.toolName !== undefined || delta.toolInput !== undefined
      || delta.toolOutput !== undefined || delta.toolState !== undefined;
    // 工具段顺带抽取产出文件（与历史快照同一套判定）：文件清单在运行中就出现，不等回合结束重取历史
    const files: DisplayPart[] = toolMediaParts(delta.toolInput, delta.toolOutput);
    if (idx >= 0) {
      const cur: DisplayMessage = res[idx];
      const parts: DisplayPart[] = mergeMediaParts(cur.parts.slice(), files);
      appendText(parts, delta.text);
      const nm: DisplayMessage = {
        id: cur.id, role: cur.role, kind: cur.kind, parts: parts,
        toolName: delta.toolName !== undefined ? delta.toolName : cur.toolName,
        toolState: delta.toolState !== undefined ? delta.toolState : cur.toolState,
        toolCallId: cur.toolCallId, toolInput: delta.toolInput !== undefined ? delta.toolInput
          : (hasTool ? cur.toolInput : cur.toolInput),
        toolOutput: delta.toolOutput !== undefined ? delta.toolOutput : cur.toolOutput,
        toolArgs: delta.toolInput !== undefined ? delta.toolInput : cur.toolArgs
      };
      res[idx] = nm;
    } else {
      const parts: DisplayPart[] = files.slice();
      appendText(parts, delta.text);
      const id: string = delta.messageId.length > 0 ? delta.messageId : `seg_${t.id}_${res.length}`;
      const seg: DisplayMessage = {
        id: id, role: 'assistant', kind: hasTool ? 'tool' : delta.kind, parts: parts,
        toolName: delta.toolName, toolState: delta.toolState,
        toolInput: delta.toolInput, toolOutput: delta.toolOutput, toolArgs: delta.toolInput
      };
      res.push(seg);
    }
    const nt: DisplayTurn = { id: t.id, user: t.user, responses: res, pending: true };
    return nt;
  }

  // 选择附件并逐个上传（对齐 RN pickAttachment：任意类型、多选、逐个 POST /api/console/upload）
  private async attach(): Promise<void> {
    if (this.conn === null || this.uploading) {
      return;
    }
    const conn: QpConnection = this.conn;
    this.uploading = true;
    this.errorMsg = '';
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const picked: PickedFile[] = await pickFiles(ctx);
      const added: PendingAttachment[] = [];
      for (const f of picked) {
        try {
          const up: UploadResult = await uploadAttachment(conn.baseUrl, conn.token, conn.agentId,
            f.path, f.name, f.mime);
          const item: PendingAttachment = {
            id: up.url, name: up.fileName, kind: f.kind, url: up.url, fileName: up.fileName
          };
          added.push(item);
        } finally {
          removeTemp(f.path);   // 上传完成即清理沙箱临时文件
        }
      }
      this.attachments = this.attachments.concat(added);
    } catch (e) {
      this.errorMsg = this.t($r('app.string.chat_attach_failed'));
    } finally {
      this.uploading = false;
    }
  }

  private removeAttachment(id: string): void {
    this.attachments = this.attachments.filter((a: PendingAttachment): boolean => a.id !== id);
  }

  // 附件 → content 分片（对齐 RN：image/video/audio 前缀判定，其余按文件）
  private attachmentParts(): ChatInputPart[] {
    const out: ChatInputPart[] = [];
    for (const a of this.attachments) {
      if (a.kind === 'image') {
        const p: ChatInputPart = { type: 'image', image_url: a.url };
        out.push(p);
      } else if (a.kind === 'video') {
        const p: ChatInputPart = { type: 'video', video_url: a.url };
        out.push(p);
      } else if (a.kind === 'audio') {
        const p: ChatInputPart = { type: 'audio', data: a.url };
        out.push(p);
      } else {
        const p: ChatInputPart = { type: 'file', file_url: a.url, file_name: a.fileName };
        out.push(p);
      }
    }
    return out;
  }

  private send(): void {
    // 循环模式（运行方式）在 7378 是发送前对文本加斜杠命令，且一次性生效
    const text: string = applyLoopCommand(this.draft.trim(), takeLoopCommand());
    if ((text.length === 0 && this.attachments.length === 0) || this.sending || this.conn === null) {
      return;
    }
    const conn: QpConnection = this.conn;
    const parts: ChatInputPart[] = [];
    if (text.length > 0) {
      const tp: ChatInputPart = { type: 'text', text: text };
      parts.push(tp);
    }
    for (const p of this.attachmentParts()) {
      parts.push(p);
    }
    // 本地回显：无文字时以附件名代替（附件本体随 content 分片发送）
    const echo: string = text.length > 0 ? text
      : this.attachments.map((a: PendingAttachment): string => a.name).join('、');
    this.attachments = [];
    this.errorMsg = '';
    this.draft = '';
    this.sending = true;
    this.stickBottom = true;
    const userPart: DisplayPart = { type: 'text', text: echo };
    const userMsg: DisplayMessage = { id: `user_${Date.now()}`, role: 'user', kind: 'message', parts: [userPart] };
    const liveTurn: DisplayTurn = {
      id: `turn_${Date.now()}`, user: userMsg, responses: [], pending: true
    };
    const pendCtx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const pend: PendingTurn = { turnId: liveTurn.id, text: text.length > 0 ? text : echo };
    this.pending = pend;
    savePendingTurn(pendCtx, conn.baseUrl, conn.agentId, this.chatId, pend);
    const next: DisplayTurn[] = this.turns.slice();
    next.push(liveTurn);
    this.liveTurnId = liveTurn.id;
    this.turns = next;
    this.scrollBottom(true);
    this.stream = streamChat(conn.baseUrl, conn.token, conn.agentId,
      this.sessionId.length > 0 ? this.sessionId : this.chatId, parts, sessionApproval(), this.userId,
      (delta: StreamDelta): void => {
        this.appendDelta(delta);
      },
      (error: string | null): void => {
        this.sending = false;
        this.stream = null;
        if (error !== null) {
          this.errorMsg = error;
          // 发送失败：本地在途记录一并清掉（对齐 7378 send 的 catch → clearPendingChatTurn）
          // 注意只清"在途标记"，列表里已挂上的那条回显不主动抹掉——消息多半已经发出去了，
          // 由紧随其后的重取按服务端实际内容对齐（服务端没有它，回显自然就退了）
          const c: QpConnection | null = this.conn;
          if (c !== null) {
            clearPendingTurn(getContext(this) as common.UIAbilityContext, c.baseUrl, c.agentId,
              this.chatId);
          }
          this.pending = null;
          this.liveTurnId = '';
        }
        // 流结束（成功或失败）都全量重取历史：补齐 reasoning/tool 块，并把 live turn 与
        // 服务端已落库的真实消息对齐（对齐 RN store.send 的 finally → loadChat）。
        this.reloadTurns();
      });
  }

  private stop(): void {
    if (this.stream !== null) {
      this.stream.stop();
      this.stream = null;
    }
    this.sending = false;
    if (this.conn !== null) {
      const conn: QpConnection = this.conn;
      stopChat(conn.baseUrl, conn.token, conn.agentId, this.chatId)
        .then((): void => {
          this.reloadTurns();
        })
        .catch((): void => {
          // 停止失败不阻塞 UI：本地流已断开，仍重取已生成内容
          this.reloadTurns();
        });
    }
  }

  // ============ 标题栏菜单（对齐 7378 app/chat/[id].tsx 头部动作）============
  // 7378 菜单首项是「会话控制」（打开模型面板）；本页把模型/循环/审批做成常驻输入条
  // （components/SessionRuntimeBar），不再藏进菜单，故菜单只保留 置顶 / 归档 / 删除。
  private titleMenu(): HdsNavigationMenuContentOptions {
    const items: Array<HdsNavigationMenuItemOptions> = [];
    items.push({
      content: {
        label: this.chatPinned ? $r('app.string.chat_menu_unpin') : $r('app.string.chat_menu_pin'),
        // 图标 = 7378 同一枚 lucide（Pin / 已置顶时 PinOff），落到 base/media
        icon: this.chatPinned ? $r('app.media.pin_off') : $r('app.media.pin'),
        action: (): void => {
          this.togglePin();
        }
      }
    });
    items.push({
      content: {
        label: $r('app.string.chat_menu_archive'),
        icon: $r('app.media.archive'),
        action: (): void => {
          this.archiveChat();
        }
      }
    });
    items.push({
      content: {
        label: $r('app.string.chat_menu_delete'),
        icon: $r('app.media.trash_2'),
        action: (): void => {
          this.confirmDeleteChat();
        }
      }
    });
    return { value: items };
  }

  // 会话元信息（置顶态）：会话详情接口只回消息与运行状态，置顶态取自会话列表里本会话那一项
  private loadChatMeta(conn: QpConnection): void {
    fetchChats(conn.baseUrl, conn.token, conn.agentId, false).then((list: ChatInfo[]): void => {
      for (const c of list) {
        if (c.id === this.chatId) {
          this.chatPinned = c.pinned;
          return;
        }
      }
    }).catch((e: Object): void => {
      // 元信息取不到不影响会话本身，菜单里的置顶项按未置顶显示
    });
  }

  private togglePin(): void {
    const conn: QpConnection | null = this.conn;
    if (conn === null) {
      return;
    }
    const next: boolean = !this.chatPinned;
    pinChat(conn.baseUrl, conn.token, conn.agentId, this.chatId, next).then((): void => {
      this.chatPinned = next;
      this.getUIContext().getPromptAction().showToast({
        message: this.t(next ? $r('app.string.chat_menu_pin') : $r('app.string.chat_menu_unpin'))
      });
    }).catch((e: Object): void => {
      this.getUIContext().getPromptAction().showToast({
        message: this.t($r('app.string.chat_op_failed'))
      });
    });
  }

  // 归档：成功后退回会话列表（对齐 7378 archive → router.back()）
  private archiveChat(): void {
    const conn: QpConnection | null = this.conn;
    if (conn === null) {
      return;
    }
    setChatArchived(conn.baseUrl, conn.token, conn.agentId, this.chatId, true).then((): void => {
      this.closePage();
    }).catch((e: Object): void => {
      this.getUIContext().getPromptAction().showToast({
        message: this.t($r('app.string.chat_op_failed'))
      });
    });
  }

  // 删除：二次确认（对齐 7378 actionMenu 的 confirmDelete 态），成功后退回会话列表
  private confirmDeleteChat(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.chat_menu_delete_title'),
      message: $r('app.string.chat_menu_delete_msg'),
      primaryButton: {
        value: this.t($r('app.string.common_cancel')),
        action: (): void => {}
      },
      secondaryButton: {
        value: this.t($r('app.string.common_confirm_delete')),
        fontColor: $r('app.color.status_error'),
        action: (): void => {
          this.doDeleteChat();
        }
      }
    });
  }

  private doDeleteChat(): void {
    const conn: QpConnection | null = this.conn;
    if (conn === null) {
      return;
    }
    deleteChat(conn.baseUrl, conn.token, conn.agentId, this.chatId).then((): void => {
      this.closePage();
    }).catch((e: Object): void => {
      this.getUIContext().getPromptAction().showToast({
        message: this.t($r('app.string.chat_op_failed'))
      });
    });
  }

  private closePage(): void {
    const stack: NavPathStack | null = this.stack;
    if (stack !== null) {
      stack.pop(true);
    }
  }

  build() {
    HdsNavDestination() {
      Column() {
        Row() {
          // 输入条 = ArkUI Tabs 的「悬浮页签栏」：barPosition=End + barOverlap +
          // barFloatingStyle.systemMaterial 是官方「非标题栏、非 HdsTabs」的原生沉浸材质载体
          // （《组件适配沉浸光感》底部页签一节 / 《沉浸光感典型场景》底部 Tabs 悬浮 + ExpandSafeArea）。
          // 材质自带交互形变（interactive）与点光源（lightEffect），栏体由系统绘制为两端纯圆胶囊。
          Tabs({ barPosition: BarPosition.End, index: 0 }) {
            TabContent() {
          // 悬浮层：Stack 底对齐——消息区（Column，铺满、底部留白）在下层，
          // 悬浮输入胶囊（圆角+玻璃底+实时磨砂+投影）浮于其上（对齐「悬浮圆角胶囊 + 沉浸光感」）。
          Stack({ alignContent: Alignment.Bottom }) {
            Column() {
            if (!this.listShown) {
              // 数据未到位用骨架屏占位（官方 FAQ faqs-arkui-1489：组件"突然出现"会造成闪动，
              // 建议用骨架屏）；历史到位后整块替换为真实列表。
              ChatSkeleton()
                .width('100%')
                .layoutWeight(1)
            } else {
            List({ scroller: this.scroller, initialIndex: this.initialRowIndex() }) {
              // 首项占位 = 沉浸标题栏高度：留白必须落在**列表内容**里，不能加在包住 List 的容器上
              // （容器 padding 会把视口裁到标题栏之下 → 消息滚不过去 → 磨砂/渐变模糊没有内容可模糊）
              ListItem() {
                Column().width('100%').height(UiTokens.topInset)
              }
              // 一行 = 一个 ListItem（用户气泡 / 消息段气泡 / 步骤组卡 / 工具产出媒体 / 待发占位）：
              // List 的虚拟化对每行生效，只有"正在长的那一行"参与重排（此前整回合一个 ListItem，
              // 流式期间每个 flush 都重排整个巨大 item，含数百行过程卡 → 滚动卡死）。
              // 末行也在这里（见 allRows 注释）：内容变化由行对象的 @ObjectLink 原地更新。
              ForEach(this.allRows(), (r: ConversationRow) => {
                ListItem() {
                  ChatRow({
                    row: r,
                    isDark: this.isDark,
                    theme: this.theme,
                    baseUrl: this.conn !== null ? this.conn.baseUrl : '',
                    onToggleSteps: (k: string): void => {
                      this.toggleSteps(k);
                    }
                  })
                }
                // 卡片插入走过渡（过渡自带动画参数，不依赖外层 animateTo）：淡入 + 轻微上移
                .transition(rowTransition())
              }, (r: ConversationRow) => r.key)
              // 末项占位 = 悬浮输入胶囊 + 其上的运行状态条：滚到底时最后一条消息（含文件清单卡）
              // 停在两条之上，其余消息从两条下滚过被实时模糊
              ListItem() {
                Column().width('100%').height(UiTokens.chatListEndInset)
              }
            }
            .layoutWeight(1)
            .width('100%')
            // 从底部开始布局（官方 FAQ faqs-arkui-1519 场景二：聊天列表用 stackFromEnd(true) 从底部加载，
            // 配合 scrollEdge(Edge.Bottom) 回最新位置；该属性从 API 19 起支持）。
            // 为什么必须它：initialIndex 只决定"首个可见项"，内容不足一屏时列表仍从顶部排 —— 短会话
            // 看上去就是"消息停在最上面"；stackFromEnd 让内容整体贴底，和 IM 一致。
            .stackFromEnd(true)
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            // 贴底跟随的判定 = 滚动位置是否真的到了内容末尾（Scroller.isAtEnd）。
            // 不能用「末项可见」当判据：末项是悬浮输入胶囊的留白（120vp 高），刚往上划一点它仍可见
            // → 被判成"还贴着底" → 下一次流式 flush 又 scrollEdge(Bottom) 把阅读位置拽回底部
            //（划到底后往上划会被跳回底部）。松手判定一次：划走即停止跟随，划回底部自动恢复。
            .onReachEnd((): void => {
              this.stickBottom = true;
              this.syncBottomFab();
            })
            // 手指一按就停止跟随并冻结自动贴底（松手后由 onScrollStop 按是否到底决定是否恢复）
            .onTouch((e: TouchEvent): void => {
              if (e.type === TouchType.Down) {
                this.userTouching = true;
                this.stickBottom = false;
              } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                this.userTouching = false;
              }
            })
            // 滚动过程中持续同步（按钮的出现/消失跟手，而不是等松手才出现）
            .onScroll((): void => {
              this.syncBottomFab();
            })
            .onScrollStop((): void => {
              this.stickBottom = this.scroller.isAtEnd();
              this.syncBottomFab();
            })
            }

          // 底部固定块（错误行 / 待发附件 / 待审批卡）：只在确有内容时占位——整组抬到悬浮输入胶囊之上，
          // 避免被胶囊压住；无内容时不占位，消息列表保持整屏（底部实时模糊的前提）
          if (this.errorMsg.length > 0 || this.attachments.length > 0 || this.uploading
            || this.approvals.length > 0) {
          Column() {
          if (this.errorMsg.length > 0) {
            Text(this.errorMsg)
              .fontSize(UiTokens.fsCaption)
              .fontColor($r('app.color.status_error'))
              .width('100%')
              .padding({ left: 4, right: 4, bottom: 6 })
              .wordBreak(WordBreak.BREAK_ALL)
          }

          // 待发附件胶囊（点 ✕ 移除）；上传中显示转圈
          if (this.attachments.length > 0 || this.uploading) {
            Row() {
              if (this.uploading) {
                LoadingProgress()
                  .width(18)
                  .height(18)
                  .color(this.isDark ? this.theme.accentDark : this.theme.accent)
                  .margin({ right: 6 })
              }
              ForEach(this.attachments, (a: PendingAttachment) => {
                Row() {
                  Text(a.name)
                    .fontSize(UiTokens.fsCaption)
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .constraintSize({ maxWidth: 180 })
                  Image($r('app.media.x'))
                    .width(12).height(12)
                    .fillColor($r('app.color.text_tertiary'))
                    .margin({ left: 6 })
                    .onClick((): void => {
                      this.removeAttachment(a.id);
                    })
                }
                .height(28)
                .padding({ left: 10, right: 10 })
                .margin({ right: 6, top: 4 })
                .borderRadius(UiTokens.chipRadius)
                .backgroundColor($r('app.color.card_bg'))
              }, (a: PendingAttachment) => a.id)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }

          // 本会话待审批（对齐 RN：多条时显示计数，卡片显示第一条；composer 上方）
          if (this.approvals.length > 0) {
            Column() {
              if (this.approvals.length > 1) {
                Text(this.t($r('app.string.chat_approvals_count')).replace('%d',
                  this.approvals.length.toString()))
                  .fontSize(UiTokens.fsCaption)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ bottom: 6 })
              }
              ApprovalCard({
                item: this.approvals[0],
                onDeny: (): void => {
                  this.actApproval(this.approvals[0], 'exact', true);
                },
                onApprove: (scope: string): void => {
                  this.actApproval(this.approvals[0], scope, false);
                }
              })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          }
          .width('100%')
          .margin({ bottom: UiTokens.chatComposerInset })
          }
            }
            .width('100%')
            .height('100%')
        // 「一键回到底部」：浮在消息区底部、让开输入胶囊与运行状态条（对齐 console 用的 SDK
        // BubbleList 里那颗 ScrollToBottom：圆形下箭头、贴底居中、距底超过阈值才出现）。
        // 隐藏态是"下移自身高度 + 透明 + 不接收点击"，进出场 200ms —— 与 console 的 0.2s 过渡一致。
        // 外观载体用 Toggle(ToggleType.Button) 而不是 Button：本按钮在内容区，官方口径下
        // Button 挂组件级 systemMaterial 会被打印 `Material inactive: out of scope` 而完全不生效
        // （真机实证），而 Toggle 在「全页面生效」名单内、官方明确 `ToggleType.Button` 效果与
        // Button 组件设置沉浸光感相同（聊天页底部状态条三枚芯片同一路径）。
        // isOn 固定 false：只借材质与交互形变，不留选中态（每次点按都当作"回到底部"）。
        Toggle({ type: ToggleType.Button, isOn: false }) {
          SymbolGlyph($r('sys.symbol.arrow_down'))
            .fontSize(20)
            .fontColor([$r('app.color.text_primary_strong')])
        }
        .width(BOTTOM_FAB_SIZE)
        .height(BOTTOM_FAB_SIZE)
        .borderRadius(BOTTOM_FAB_SIZE / 2)
        // 透明底：玻璃观感由沉浸材质给（官方示例即「透明底 + ImmersiveMaterial」）
        .backgroundColor(Color.Transparent)
        // 沉浸材质 THIN：档位随设备算力自适应、跟随系统「沉浸光感」开关；interactive = 交互形变、
        // lightEffect 取服务端同步的主题色（ThemeManager 的快照，console 主题改色这边跟着变）
        .systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.THIN,
          interactive: true,
          lightEffect: { color: this.theme.accent }
        }))
        .selectedColor(Color.Transparent)
        .shadow({ radius: 12, color: '#40000000', offsetX: 0, offsetY: 2 })
        .margin({ bottom: this.bottomFabOffset() })
        .opacity(this.atBottom ? 0 : 1)
        .translate({ y: this.atBottom ? BOTTOM_FAB_SIZE : 0 })
        .hitTestBehavior(this.atBottom ? HitTestMode.None : HitTestMode.Default)
        .animation({ duration: BOTTOM_FAB_ANIM_MS, curve: Curve.EaseOut })
        // Toggle 每次点按都翻转内部开关态 → 不区分方向都触发动作（本按钮没有"取消"语义）
        .onChange((isOn: boolean): void => {
          this.jumpToBottom();
        })
        }
        .width('100%')
        .height('100%')
        // 左右留白挂在滚动区容器（外层 Stack）上，不是最外层 Column：外层铺满屏幕左右，
        // 输入条父容器（Tabs）才能扩到屏幕边缘，不在两侧露出窗口底色
        .padding({ left: UiTokens.pageHMargin, right: UiTokens.pageHMargin })
            }
            .tabBar(this.composerBar())
          }
          .barOverlap(true)
          .scrollable(false)
          // 胶囊只承载输入行（状态条已移出，浮在胶囊之上）
          .barHeight(UiTokens.chatComposerHeight + 1)
          // 会话运行状态条：浮层定位在胶囊之上 3vp（官方 overlay：不重新渲染 TabBar 即可叠加组件）
          .overlay(this.runtimeRow(), {
            align: Alignment.Bottom,
            offset: {
              x: 0,
              y: -(UiTokens.chatComposerBottomMargin + UiTokens.chatComposerHeight + 1
                + UiTokens.chatRuntimeRowGap)
            }
          })
          .barFloatingStyle({
            // 悬浮栏默认按内容自适应宽度（实测输入框被压到 112px）→ 显式给宽度：
            // 344vp + 两侧 16vp = 376vp = 屏幕全宽（1316px @3.5）
            barWidth: { smallBarWidth: 344, mediumBarWidth: 344, largeBarWidth: 344 },
            barSideMargin: UiTokens.pageHMargin,
            // 栏体背板遮罩默认近黑：按压/拖动时栏体形变，遮罩露出即"黑边遮挡"（真机拖拽实测
            // 遮罩节点 BackgroundMask x56-1260 y2531-2832，漏出的行取值为 2~5）→ 置透明
            maskColor: Color.Transparent,
            barBottomMargin: 12,
            systemMaterial: new uiMaterial.ImmersiveMaterial({
              style: uiMaterial.ImmersiveStyle.THIN,
              interactive: true,
              lightEffect: { color: this.theme.accent }
            })
          })
          .width('100%')
          .height('100%')
        }
        .width(wideClampW(this.pageW))
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
    }
      .width('100%')
      .height('100%')
      // 键盘弹起时把底部让出来，悬浮输入条随之抬到键盘之上（与 NONE 模式配套）
      .padding({ bottom: this.keyboardInset })
      .backgroundColor($r('app.color.page_bg'))
      .onAreaChange(this.onChatArea)
      // 沉浸到状态栏 / 导航栏 / 屏幕左右两侧：绘制区扩到安全区之外（官方 expandSafeArea），
      // 否则上带显示系统壁纸、下带露出导航条底色、左右露出窗口底色的黑带
      .expandSafeArea([SafeAreaType.SYSTEM],
        [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
    }
    // 内容也扩到安全区外（布局级）：官方 NavDestination.ignoreLayoutSafeArea，
    // 与 expandSafeArea 同时设置时它优先；前置条件要求标题栏隐藏或 STACK 模式
    .onShown((): void => {
      this.applySessionApproval();
    })
    // 二级页转场：整页自右水平覆盖进来（退出滑回右侧）——见 services/NavPush.slideCoverTransition。
    // 系统默认档在分栏下动的是"内容区左边缘 0 → 分栏位"，观感从左侧摊过来（判"方向反了"），
    // 故改用官方 customTransition（NavDestinationTransitionDelegate）自己定方向。
    .customTransition((op: NavigationOperation, isEnter: boolean)
      : Array<NavDestinationTransition> | undefined => slideCoverTransition(op, isEnter,
        (v: string): void => { this.pageX = v; }))
    .translate({ x: this.pageX })
    // 返回键：本页显式出栈并消费。单栏/分栏下系统返回都不会自动弹本页
    // （平板横屏实测按返回直接退到桌面），出栈后右栏回到空态占位（QwenPaw 形象）。
    .onBackPressed((): boolean => {
      const stack: NavPathStack | null = this.stack;
      if (stack !== null && stack.size() > 0) {
        stack.pop();
      }
      return true;
    })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],
      [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM, LayoutSafeAreaEdge.START, LayoutSafeAreaEdge.END])
    .titleBar({
      // 静止态即磨砂（聊天详情页）：默认配置是"静止透明、动一下才出磨砂"，
      // 官方 GRADIENT_BLUR + enableScrollEffect=false 组合的 originalStyle 背景色默认 #99000000，
      // 进页面即有一条清晰磨砂顶栏；内容滚过时继续被模糊。
      style: {
        // 与主页同款沉浸：沉浸式渐变模糊 + 系统材质（等级 ADAPTIVE），静止态与滚动终点态都用主题色底。
        // 平台行为：深色下沉浸材质是"变暗玻璃"，会把底色压低（观感偏"透明"，属沉浸固有表现）。
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
            backgroundColor: this.isDark ? this.theme.accentDark : this.theme.accent
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            blurRadius: 12.0,
            backgroundColor: this.isDark ? this.theme.accentDark : this.theme.accent
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        title: {
          mainTitle: this.chatName.length > 0 ? this.chatName : $r('app.string.chat_title')
        },
        // 标题栏菜单（置顶 / 归档 / 删除）：对齐 7378 chat/[id].tsx 头部动作菜单
        menu: this.titleMenu()
      },
      // 与主页一致：标题栏不避让安全区向上铺到状态栏区域，组件安全区关闭（否则状态栏带露系统底）
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: false
    })
    // 归档/删除成功后需要退回会话列表：页面自身没有导航栈入参，
    // 按官方 NavDestinationContext.pathStack 在 ready 时取一次
    .onReady((ctx: NavDestinationContext): void => {
      this.stack = ctx.pathStack;
    })
  }
}

// ============ 会话详情页用的显示纯逻辑 ============
// 行渲染（气泡 / 步骤组卡 / 媒体 / 分发器）已拆到 components/ChatRows.ets；
// 这里只留页面自身用到的分片辅助函数。

// 追加文本到分片数组：合并进末尾 text 分片，否则新起一片（流式 delta 归并用）。
// 空文本直接返回 —— 工具段本就没有文本载荷，不该因此多挂一个空 text 分片；
// 尚无文本分片时纯空白（服务端会发 "\n\n" 这类分片）也跳过，否则会先落一张空卡再等正文。
function appendText(parts: DisplayPart[], text: string): void {
  if (text.length === 0) {
    return;
  }
  const lastIdx: number = parts.length - 1;
  const hasText: boolean = lastIdx >= 0 && parts[lastIdx].type === 'text';
  if (!hasText && text.trim().length === 0) {
    return;
  }
  if (lastIdx >= 0 && parts[lastIdx].type === 'text') {
    const lp: DisplayPart = parts[lastIdx];
    parts[lastIdx] = { type: 'text', text: (lp.text !== undefined ? lp.text : '') + text };
  } else {
    const np: DisplayPart = { type: 'text', text: text };
    parts.push(np);
  }
}

// 卡片插入/移除的过渡：淡入淡出 + 轻微上移。显式给两段各自的 animation 参数 —— 过渡不依赖
// 外层 animateTo（把数据写入包进 animateTo 会把同一帧里"正在变高的流式文本"一起补间，整块会一直
// 呼吸/闪；官方 faqs-arkui-622 也把"过渡写错/依赖外部动画上下文"列为闪动来源）。
function rowTransition(): TransitionEffect {
  const anim: AnimateParam = { duration: EXPAND_ANIM_MS, curve: Curve.EaseOut };
  return TransitionEffect.OPACITY.animation(anim)
    .combine(TransitionEffect.translate({ y: 12 }).animation(anim));
}

// 该分段是否有可显示内容：按**可见性**判定（非空白文本 / 媒体分片 / 错误）——服务端会下发 text
// 只有 "\n\n" 的 message 记录（实测同一会话 26 条），按"分片非空"判定会放过它，结果渲染成一张
// 只有卡片底色的空白卡（真机表现为"每个气泡中间夹着一张空白卡"）。
function messagesHaveContent(msgs: DisplayMessage[]): boolean {
  for (const m of msgs) {
    if (rowHasVisibleContent(m)) {
      return true;
    }
  }
  return false;
}
