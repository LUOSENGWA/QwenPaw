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
import { sessionApproval, takeLoopCommand, applyLoopCommand } from '../services/SessionControls';
import { PendingTurn, loadPendingTurn, savePendingTurn, clearPendingTurn } from '../services/PendingTurn';
import {
  DisplayTurn, DisplayMessage, DisplayPart, ChatSnapshot, fetchChatMessages, streamChat, reconnectChat, stopChat,
  ChatStreamHandle, ChatInputPart, UploadResult, uploadAttachment, CHAT_CLOSED_EVENT,
  ResponseBlock, responseBlocks, answerIndexOf, resultMediaOf, textOfParts, partsTextLen
} from '../services/ChatDetailService';
import { pickFiles, removeTemp, PickedFile } from '../services/AttachmentPicker';
import { StreamDelta } from '../services/SseParser';
import { ApprovalInfo, fetchApprovals, approveRequest, denyRequest } from '../services/ApprovalsService';
import { fetchChats, ChatInfo, pinChat, setChatArchived, deleteChat } from '../services/ChatsService';
import { ApprovalCard } from '../components/ApprovalCard';
import { SessionRuntimeBar } from '../components/SessionRuntimeBar';
import { ChatRow, ConversationRow, mergeToolMessages } from '../components/ChatRows';
import { ChatSkeleton } from '../components/ChatSkeleton';
import { ThemeManager, ThemeSnapshot, ThemeListener } from '../theme/ThemeManager';
import { UiTokens, pxPerVp } from '../theme/UiTokens';
import { blendHex } from '../theme/Accent';
import { PRESS_SCALE, PressLatch, pressEffect, pressTouch } from '../theme/PressFx';

@Builder
export function ChatDetailPageBuilder(_name: string, param: Object) {
  ChatDetailPage({ params: param })
}

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
  @State @Watch('onTurnsChanged') turns: DisplayTurn[] = [];
  // 展开中的过程组（键 = turnId:块序号）：扁平化后组内行是页面 List 的独立项，
  // 因此「哪一组展开」必须由页面持有，而不能留在组卡组件内部
  @State expandedGroups: string[] = [];
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
  private streamMsgId: string = '';
  // 当前 message 流的 messageId（对齐 7378 store.send/reconnectChat 的 activeMessageId：
  // messageId 变化即视为新一段文本，重置而不是续写）
  private liveAnswerMsgId: string = '';
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

  // 在途回合对账（对齐 7378 loadChat）：历史里已有同文本的用户消息且当前不在跑 → 清本地记录；
  // 否则把在途那条合并回列表（已合并过则跳过），保证"切走再回来自己那条不丢"。
  private async reconcilePending(running: boolean): Promise<void> {
    const conn: QpConnection | null = this.conn;
    if (conn === null) {
      return;
    }
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const rec: PendingTurn | null = await loadPendingTurn(ctx, conn.baseUrl, conn.agentId, this.chatId);
    if (rec === null) {
      this.pending = null;
      return;
    }
    if (lastUserTextOf(this.turns) === rec.text && !running) {
      await clearPendingTurn(ctx, conn.baseUrl, conn.agentId, this.chatId);
      this.pending = null;
      return;
    }
    this.pending = rec;
    for (const t of this.turns) {
      if (t.id === rec.turnId) {
        return;
      }
    }
    const up: DisplayPart = { type: 'text', text: rec.text };
    const um: DisplayMessage = { id: `u_${rec.turnId}`, role: 'user', kind: 'message', parts: [up] };
    const lt: DisplayTurn = { id: rec.turnId, user: um, responses: [], pending: true };
    const arr: DisplayTurn[] = this.turns.slice();
    arr.push(lt);
    this.turns = arr;
  }

  // 会话展平成行序列（一行 = 一个 ListItem 的载荷）。顺序：用户气泡 → 响应分段（消息段 / 步骤组）
  // → 待发占位（仅当该回合还没出可见文本）→ 该回合工具产出媒体。
  private rows(): ConversationRow[] {
    const out: ConversationRow[] = [];
    for (const turn of this.turns) {
      const tid: string = turn.id;
      if (turn.user !== null) {
        const u: DisplayMessage = turn.user;
        out.push({ key: `u:${tid}`, kind: 'user', turnId: tid, messages: [u], parts: [],
          pending: turn.pending, last: false, generating: false });
      }
      // 响应按 console 口径分段（responseBlocks，语义不改）：message 段逐段可见、其余收进 steps 组
      const blocks: ResponseBlock[] = responseBlocks(turn.responses, turn.pending);
      // 活动组 = 末块为 steps 的那一组（对齐 console findActiveStepBlockIndex：末块是 message 则无活动组）：
      // 只有活动组处于「生成中」，其状态文案与转圈随生成推进；其余组一律视为已完成。
      const activeStep: number = turn.pending && blocks.length > 0
        && blocks[blocks.length - 1].kind === 'steps' ? blocks.length - 1 : -1;
      for (let i = 0; i < blocks.length; i++) {
        const b: ResponseBlock = blocks[i];
            // 键 = 回合 + 块序号（结构键，不含文本长度/片段等指纹）：块内容是流式增长的，
        // 若把指纹放进键，每次 flush 键都变 → 键变化即重建子树（闪烁 + 打断滚动/展开态）
        if (b.kind === 'message') {
          out.push({ key: `m:${tid}:${i}`, kind: 'message', turnId: tid, messages: b.messages, parts: [],
            pending: turn.pending, last: !turn.pending, generating: false });
        } else {
          // 过程组 = 组头一条 +（展开时）组内每行各一条独立列表项：
          // 一行一个 ListItem 才能吃到 List 的虚拟化（此前整组一个 item，数百行一次性构建）
          const gk: string = `${tid}:${i}`;
          const expanded: boolean = (i === activeStep && turn.pending)
            || this.expandedGroups.indexOf(gk) >= 0;
          out.push({ key: `sh:${gk}`, kind: 'stepsHeader', turnId: tid, messages: b.messages,
            parts: [], pending: turn.pending, last: false, generating: i === activeStep,
            expanded: expanded, groupKey: gk });
          if (expanded) {
            const procs: DisplayMessage[] = mergeToolMessages(b.messages);
            for (let pi = 0; pi < procs.length; pi++) {
              out.push({ key: `pr:${gk}:${pi}`, kind: 'proc', turnId: tid,
                messages: [procs[pi]], parts: [], pending: turn.pending, last: false,
                generating: i === activeStep });
            }
          }
        }
      }
      if (turn.pending && !this.turnHasStreamText(turn)) {
        out.push({ key: `p:${tid}`, kind: 'pending', turnId: tid, messages: [], parts: [],
          pending: true, last: false, generating: false });
      }
      // 工具产出媒体（截图等）挂在整回合末尾（对齐 7378 buildTurn 的 resultMedia）
      const media: DisplayPart[] = resultMediaOf(turn.responses, answerIndexOf(turn.responses));
      if (media.length > 0) {
        out.push({ key: `x:${tid}`, kind: 'media', turnId: tid, messages: [], parts: media,
          pending: false, last: false, generating: false });
      }
    }
    return out;
  }

  // 过程组展开/收起切换（组头点击）
  private toggleSteps(gk: string): void {
    const next: string[] = this.expandedGroups.slice();
    const at: number = next.indexOf(gk);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(gk);
    }
    this.expandedGroups = next;
  }

  // 除末行外的全部行（进 ForEach，键稳定 ⇒ 不重建）
  private doneRows(): ConversationRow[] {
    const all: ConversationRow[] = this.rows();
    if (all.length === 0) {
      return all;
    }
    return all.slice(0, all.length - 1);
  }

  // 末行（挂在 ForEach 之外直接构造组件）：流式期间"正在长的那一行"就在末位，直接挂才能
  // 每帧经 @Prop 拿到新行、按常规更新路径刷新（ForEach 键不变则子组件参数也不更新 → 冻帧）
  private liveRow(): ConversationRow | null {
    const all: ConversationRow[] = this.rows();
    if (all.length === 0) {
      return null;
    }
    return all[all.length - 1];
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
      if (snap.running && this.stream === null) {
        this.attachRunningStream();
        return;
      }
      if (this.turnsDigest(snap.turns) !== this.turnsDigest(this.turns)) {
        this.turns = snap.turns;
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
      this.turns = snap.turns;
      await this.reconcilePending(snap.running);
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
    this.liveAnswerMsgId = '';
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
      this.refreshApprovals();
      this.loadChatMeta(conn);
      const snap: ChatSnapshot = await fetchChatMessages(conn.baseUrl, conn.token, conn.agentId,
        this.chatId);
      this.turns = snap.turns;
      // 身份优先取列表项带来的 user_id（详情接口不返回该字段）；详情里若有则以它为准
      if (snap.userId.length > 0) {
        this.userId = snap.userId;
      }
      await this.reconcilePending(snap.running);
      this.stickBottom = true;
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
    }, 1200);
  }
  private stickBottom: boolean = true;
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
    }, 40);
  }

  // 列表初始落点 = 末项：列表创建即停在底部，不靠多次 scrollEdge 追（追的过程就是跳变）
  private initialRowIndex(): number {
    const live: number = this.liveRow() !== null ? 1 : 0;
    return this.doneRows().length + live + 1;
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
    const arr: DisplayTurn[] = this.turns.slice();
    const li: number = arr.length - 1;
    if (li < 0) {
      return;
    }
    let t: DisplayTurn = arr[li];
    for (const d of buf) {
      t = this.mergeDeltaInto(t, d);
    }
    arr[li] = t;
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
    if (idx >= 0) {
      const cur: DisplayMessage = res[idx];
      const parts: DisplayPart[] = cur.parts.slice();
      appendText(parts, delta.text);
      const nm: DisplayMessage = {
        id: cur.id, role: cur.role, kind: cur.kind, parts: parts,
        toolName: delta.toolName !== undefined ? delta.toolName : cur.toolName,
        toolState: delta.toolState !== undefined ? delta.toolState : cur.toolState,
        toolCallId: cur.toolCallId, toolInput: delta.toolInput !== undefined ? delta.toolInput
          : (hasTool ? cur.toolInput : cur.toolInput),
        toolOutput: delta.toolOutput !== undefined ? delta.toolOutput : cur.toolOutput
      };
      res[idx] = nm;
    } else {
      const parts: DisplayPart[] = [];
      appendText(parts, delta.text);
      const id: string = delta.messageId.length > 0 ? delta.messageId : `seg_${t.id}_${res.length}`;
      const seg: DisplayMessage = {
        id: id, role: 'assistant', kind: delta.kind, parts: parts,
        toolName: delta.toolName, toolState: delta.toolState,
        toolInput: delta.toolInput, toolOutput: delta.toolOutput
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
    this.streamMsgId = '';
    this.liveAnswerMsgId = '';
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
          const c: QpConnection | null = this.conn;
          if (c !== null) {
            clearPendingTurn(getContext(this) as common.UIAbilityContext, c.baseUrl, c.agentId,
              this.chatId);
          }
          this.pending = null;
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
            ChatSkeleton({ isDark: this.isDark })
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
            ForEach(this.doneRows(), (r: ConversationRow) => {
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
            }, (r: ConversationRow) => r.key)
            // 末行不进 ForEach：官方口径《ForEach 循环渲染·键值生成规则》——「当键值变化时，
            // 框架会基于新的键值创建一个新的组件」，键不变则不重跑 itemGenerator，子组件参数也不更新；
            // 而"正在长的那一行"内容一直在变、键不变 ⇒ 流式期间界面会冻在载入那一帧。
            // 直接挂在 ForEach 之外：父组件每次 flush 重跑 build → ChatRow 经 @Prop 拿到新行按常规
            // 更新路径刷新，逐字可见、且不重建子树（展开态/选择态不被打断）。
            if (this.liveRow() !== null) {
              ListItem() {
                ChatRow({
                  row: this.liveRow() as ConversationRow,
                  isDark: this.isDark,
                  theme: this.theme,
                  baseUrl: this.conn !== null ? this.conn.baseUrl : '',
                  onToggleSteps: (k: string): void => {
                    this.toggleSteps(k);
                  }
                })
              }
            }
            // 末项占位 = 悬浮输入胶囊高度：滚到底时最后一条消息停在胶囊之上，其余消息从胶囊下滚过被实时模糊
            ListItem() {
              Column().width('100%').height(UiTokens.chatComposerInset)
            }
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          // 贴底跟随的判定 = 滚动位置是否真的到了内容末尾（Scroller.isAtEnd）。
          // 不能用「末项可见」当判据：末项是悬浮输入胶囊的留白（120vp 高），刚往上划一点它仍可见
          // → 被判成"还贴着底" → 下一次流式 flush 又 scrollEdge(Bottom) 把阅读位置拽回底部
          //（划到底后往上划会被跳回底部）。松手判定一次：划走即停止跟随，划回底部自动恢复。
          .onReachEnd((): void => {
            this.stickBottom = true;
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
          .onScrollStop((): void => {
            this.stickBottom = this.scroller.isAtEnd();
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
      .width('100%')
      .height('100%')
      // 键盘弹起时把底部让出来，悬浮输入条随之抬到键盘之上（与 NONE 模式配套）
      .padding({ bottom: this.keyboardInset })
      .backgroundColor($r('app.color.page_bg'))
      // 沉浸到状态栏 / 导航栏 / 屏幕左右两侧：绘制区扩到安全区之外（官方 expandSafeArea），
      // 否则上带显示系统壁纸、下带露出导航条底色、左右露出窗口底色的黑带
      .expandSafeArea([SafeAreaType.SYSTEM],
        [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
    }
    // 内容也扩到安全区外（布局级）：官方 NavDestination.ignoreLayoutSafeArea，
    // 与 expandSafeArea 同时设置时它优先；前置条件要求标题栏隐藏或 STACK 模式
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
// 这里只留页面自身用到的两个分片辅助函数。

// 列表里最后一条用户消息的文本（在途回合对账用）
function lastUserTextOf(list: DisplayTurn[]): string {
  for (let i = list.length - 1; i >= 0; i--) {
    const u: DisplayMessage | null = list[i].user;
    if (u !== null) {
      let out: string = '';
      for (const p of u.parts) {
        if (p.type === 'text' && p.text !== undefined) {
          out += p.text;
        }
      }
      return out;
    }
  }
  return '';
}

// 追加文本到分片数组：合并进末尾 text 分片，否则新起一片（流式 delta 归并用）
function appendText(parts: DisplayPart[], text: string): void {
  const lastIdx: number = parts.length - 1;
  if (lastIdx >= 0 && parts[lastIdx].type === 'text') {
    const lp: DisplayPart = parts[lastIdx];
    parts[lastIdx] = { type: 'text', text: (lp.text !== undefined ? lp.text : '') + text };
  } else {
    const np: DisplayPart = { type: 'text', text: text };
    parts.push(np);
  }
}
