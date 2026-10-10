/*
 * 会话详情 —— 移植 PR #7378 apps/qwenpaw-mobile/app/chat/[id].tsx 一期形态：
 *   历史（GET /api/chats/{id}）+ 输入发送（POST /api/console/chat，stream:true）流式追加 + 停止当前轮。
 * 路由参数：{ chatId, chatName }（routerMap 名 chat，由「会话」tab 的会话行打开）。
 */

import { HdsNavDestination, ScrollEffectType, BlurStrategy } from '@kit.UIDesignKit';
import { emitter } from '@kit.BasicServicesKit';
import { common, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { QpConnection, loadConnection } from '../services/ConnectionStore';
import {
  ChatMessage, ChatHistory, fetchChatMessages, streamChat, stopChat, ChatStreamHandle,
  ChatInputPart, UploadResult, uploadAttachment, CHAT_CLOSED_EVENT
} from '../services/ChatDetailService';
import { pickFiles, removeTemp, PickedFile } from '../services/AttachmentPicker';
import { StreamDelta } from '../services/SseParser';
import { ApprovalInfo, fetchApprovals, approveRequest, denyRequest } from '../services/ApprovalsService';
import { ApprovalCard } from '../components/ApprovalCard';
import { ThemeManager, ThemeSnapshot, ThemeListener } from '../theme/ThemeManager';
import { UiTokens } from '../theme/UiTokens';
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
  @State messages: ChatMessage[] = [];
  @State draft: string = '';
  @State sending: boolean = false;
  @State attachments: PendingAttachment[] = [];   // 已上传待发送的附件
  // 本会话待审批（对齐 RN chat/[id].tsx：root_session_id === chat.session_id || chat.id）
  @State approvals: ApprovalInfo[] = [];
  @State uploading: boolean = false;              // 附件上传中（按钮转圈）
  @State loading: boolean = true;
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
  private conn: QpConnection | null = null;
  private themeListener: ThemeListener | null = null;

  // 发送(0)/停止(1)按钮按压：缩放动画与点光源由 pressTouch/pressEffect 统一驱动
  private onBtnTouch(idx: number, e: TouchEvent): void {
    pressTouch(this.getUIContext(), e, this.btnLatch, (v: boolean): void => {
      this.btnPressed = v ? idx : -1;
    });
  }

  aboutToAppear(): void {
    const rec: Record<string, Object> = this.params as Record<string, Object>;
    const id: Object = rec['chatId'];
    const name: Object = rec['chatName'];
    this.chatId = typeof id === 'string' ? id as string : '';
    this.chatName = typeof name === 'string' ? name as string : '';
    const sid: Object = rec['sessionId'];
    this.sessionId = typeof sid === 'string' && (sid as string).length > 0 ? sid as string : this.chatId;
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
      this.refreshHistory();
      this.refreshApprovals();
    }, 3000);
  }

  aboutToDisappear(): void {
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

  // 静默重取历史：Console 侧新增消息时同步过来（本地刚发的那条在服务端也已在列，条数一致则不动）
  private async refreshHistory(): Promise<void> {
    if (this.sending || this.conn === null) {
      return;
    }
    try {
      const conn: QpConnection = this.conn;
      const history: ChatHistory = await fetchChatMessages(conn.baseUrl, conn.token, conn.agentId,
        this.chatId);
      if (history.messages.length !== this.messages.length) {
        this.messages = history.messages;
        this.scrollBottom();
      }
    } catch (e) {
      // 静默刷新失败不影响页面
    }
  }

  // 思考 / 工具执行过程（对齐 RN features/chat/MessageTurn.tsx：reasoning、tool 各自成块，
  // 不与正文混成同一个气泡）——流式进行中即可见
  @Builder
  processRow(m: ChatMessage) {
    Row() {
      Column() {
        Text(m.kind.indexOf('tool') >= 0 ? $r('app.string.chat_process_tool') : $r('app.string.chat_process_think'))
          .fontSize(UiTokens.fsCaption)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ bottom: 2 })
        Text(m.text)
          .fontSize(UiTokens.fsCaption)
          .fontColor($r('app.color.text_secondary'))
          .wordBreak(WordBreak.BREAK_ALL)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: UiTokens.pageHMargin, right: UiTokens.pageHMargin, top: 4, bottom: 4 })
  }

  private async loadHistory(): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.loading = true;
    this.errorMsg = '';
    try {
      const conn: QpConnection | null = await loadConnection(ctx);
      if (conn === null) {
        this.errorMsg = this.t($r('app.string.chat_no_conn'));
        return;
      }
      this.conn = conn;
      this.refreshApprovals();
      const history: ChatHistory = await fetchChatMessages(conn.baseUrl, conn.token, conn.agentId,
        this.chatId);
      this.messages = history.messages;
      if (history.running) {
        // 服务端上一轮仍在跑：先取到历史，用户可继续输入（一期不做自动重连流）
        this.errorMsg = '';
      }
      this.scrollBottom();
    } catch (e) {
      this.errorMsg = (e as Error).message;
    } finally {
      this.loading = false;
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

  private scrollBottom(): void {
    setTimeout((): void => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 40);
  }

  // 增量归并：同一 messageId + kind 续写末尾气泡，否则新起一条
  private appendDelta(delta: StreamDelta): void {
    const next: ChatMessage[] = this.messages.slice();
    const last: ChatMessage | undefined = next.length > 0 ? next[next.length - 1] : undefined;
    if (last !== undefined && last.id === this.streamMsgId && last.kind === delta.kind) {
      next[next.length - 1] = {
        id: last.id,
        role: last.role,
        kind: last.kind,
        text: last.text + delta.text
      };
    } else {
      this.streamMsgId = delta.messageId.length > 0 ? delta.messageId : `stream_${Date.now()}`;
      next.push({
        id: this.streamMsgId,
        role: 'assistant',
        kind: delta.kind,
        text: delta.text
      });
    }
    this.messages = next;
    this.scrollBottom();
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
    const text: string = this.draft.trim();
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
    this.streamMsgId = '';
    const next: ChatMessage[] = this.messages.slice();
    next.push({ id: `user_${Date.now()}`, role: 'user', kind: 'message', text: echo });
    this.messages = next;
    this.scrollBottom();
    this.stream = streamChat(conn.baseUrl, conn.token, conn.agentId,
      this.sessionId.length > 0 ? this.sessionId : this.chatId, parts,
      (delta: StreamDelta): void => {
        this.appendDelta(delta);
      },
      (error: string | null): void => {
        this.sending = false;
        this.stream = null;
        if (error !== null) {
          this.errorMsg = error;
        }
        this.scrollBottom();
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
      stopChat(conn.baseUrl, conn.token, conn.agentId, this.chatId).catch((): void => {
        // 停止失败不阻塞 UI：本地流已断开
      });
    }
  }

  @Builder
  messageRow(m: ChatMessage) {
    Row() {
      if (m.role === 'user') {
        Blank()
      }
      Column() {
        if (m.role !== 'user' && m.kind !== 'message') {
          Text(m.kind === 'reasoning' ? $r('app.string.chat_kind_reasoning')
            : $r('app.string.chat_kind_tool'))
            .fontSize(UiTokens.fsCaption)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ bottom: 2 })
        }
        Text(m.text)
          .fontSize(UiTokens.fsBody)
          .fontColor(m.role === 'user' ? Color.White : $r('app.color.input_text'))
          .lineHeight(21)
          .wordBreak(WordBreak.BREAK_WORD)
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .constraintSize({ maxWidth: '78%' })
      .borderRadius(UiTokens.cardRadius)
      .backgroundColor(m.role === 'user'
        ? (this.isDark ? this.theme.accentDark : this.theme.accent)
        : $r('app.color.card_surface'))
      if (m.role !== 'user') {
        Blank()
      }
    }
    .width('100%')
    .margin({ top: 6, bottom: 6 })
  }

  build() {
    HdsNavDestination() {
      Column() {
        if (this.loading) {
          Text($r('app.string.chat_loading'))
            .fontSize(UiTokens.fsSecondary)
            .fontColor($r('app.color.text_tertiary'))
            .padding({ top: 32 })
        } else {
          List({ scroller: this.scroller }) {
            ForEach(this.messages, (m: ChatMessage) => {
              ListItem() {
                if (m.kind.indexOf('reasoning') >= 0 || m.kind.indexOf('thinking') >= 0
                  || m.kind.indexOf('tool') >= 0) {
                  this.processRow(m)
                } else {
                  this.messageRow(m)
                }
              }
            }, (m: ChatMessage) => m.id)
            ListItem() {
              Column().width('100%').height(12)
            }
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        }

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
                Text('✕')
                  .fontSize(UiTokens.fsCaption)
                  .fontColor($r('app.color.text_tertiary'))
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

        Row() {
          Button() {
            if (this.uploading) {
              LoadingProgress()
                .width(20)
                .height(20)
                .color(this.isDark ? this.theme.accentDark : this.theme.accent)
            } else {
              SymbolGlyph($r('sys.symbol.plus'))
                .fontSize(20)
                .fontColor([$r('app.color.btn_gray_text')])
            }
          }
          .type(ButtonType.Normal)
          .width(40)
          .height(40)
          .padding(0)
          .backgroundColor($r('app.color.card_bg'))
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
            .backgroundColor($r('app.color.card_bg'))
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
              .enabled(this.draft.trim().length > 0)
              .backgroundColor(this.isDark ? this.theme.accentDark : this.theme.accent)
              .fontColor(Color.White)
              .scale({ x: this.btnPressed === 0 ? PRESS_SCALE : 1, y: this.btnPressed === 0 ? PRESS_SCALE : 1 })
              .stateEffect(false)
              .visualEffect(pressEffect(this.btnPressed === 0))
              .onTouch((e: TouchEvent): void => {
                this.onBtnTouch(0, e);
              })
              .onClick((): void => {
                this.send();
              })
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)
        // 输入条带磨砂（内容区不能用沉浸材质，官方通用属性 backgroundBlurStyle 即实时背景模糊）：
        // 做成通栏底栏观感 —— 不加圆角卡片感，仅一条上边线分隔
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .border({ width: { top: 1 }, color: $r('app.color.line') })
      }
      .width('100%')
      .height('100%')
      .padding({ left: UiTokens.pageHMargin, right: UiTokens.pageHMargin })
      .backgroundColor($r('app.color.page_bg'))
    }
    .titleBar({
      // 静止态即磨砂（聊天详情页）：默认配置是"静止透明、动一下才出磨砂"，
      // 官方 GRADIENT_BLUR + enableScrollEffect=false 组合的 originalStyle 背景色默认 #99000000，
      // 进页面即有一条清晰磨砂顶栏；内容滚过时继续被模糊。
      style: {
        scrollEffectOpts: {
          enableScrollEffect: false,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        blurStrategy: BlurStrategy.ADAPTIVE
      },
      content: {
        title: {
          mainTitle: this.chatName.length > 0 ? this.chatName : $r('app.string.chat_title')
        }
      }
    })
  }
}
