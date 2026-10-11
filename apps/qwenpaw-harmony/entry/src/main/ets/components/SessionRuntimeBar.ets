/*
 * 聊天页 · 会话运行状态条 —— 对齐 PR #7378 features/chat/SessionRuntimeControls.tsx。
 *
 * 取数（本组件自持，不由页面下推）：
 *   GET /api/models/active                   → 当前生效模型（active_llm.model）
 *   GET /api/loops/status?chat_id&session_id → 本会话循环状态（mode.name || state）
 *   GET /api/workspace/running-config        → 运行配置里的 approval_level
 * 切换模型：PUT /api/models/active {provider_id, model, scope:"agent", agent_id} → 重新取数
 *
 * 为什么自持数据：本行挂在 Tabs 悬浮页签栏（barPosition=End 的 TabBar）内，该 builder 只在
 * 页面首次构建时执行一次，父组件之后的 @State/@Prop 变化进不了这棵子树（真机实证：传进来的
 * baseUrl/agentId 恒为空、@Link 值恒为「—」）；而子树内组件自身的 @State 变化照常刷新
 * （同一子树里的输入框打字、发送键置灰都正常）。故按其它模块组件的写法，在 aboutToAppear
 * 里自行 loadConnection + 取数，不依赖页面下推。
 *
 * 位置与材质：本行**浮在输入胶囊之上**（不在输入胶囊里：胶囊只包输入行），由聊天页用
 * Tabs 的 overlay 定位（官方《Tabs 使用 overlay 在页签栏添加自定义组件》）。
 * 材质：官方《沉浸光感常见问题》列了**全页面生效**的组件/接口——弹窗类组件与接口，以及
 * **Slider / Toggle / Select**；「其他组件仅在 Navigation/NavDestination 标题栏或横向 Tabs 中
 * barPosition=End 的底部 TabBar 中生效」（Button 属"其他组件"，在内容区挂材质会被打印
 * `Material inactive: out of scope`，真机实证）。故三个芯片用 **Toggle(ToggleType.Button)**
 * —— 官方口径「ToggleType.Button 效果与 Button 组件设置沉浸光感相同」，且在豁免名单内，
 * 内容区即可获得系统沉浸材质：档位随设备算力自适应、并跟随系统「沉浸光感」开关。
 * 交互形变（interactive）与点光源（lightEffect）替代默认按压态。
 * 说明：7378 的「会话级覆盖」存本地偏好（AsyncStorage），发送链路无对应参数，故循环/审批
 * 只呈现真实生效值，不自造选择项。
 */

import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { uiMaterial } from '@kit.ArkUI';
import { doRequest, jsonArrayOf, jsonOf } from '../services/ConnectionService';
import { loadConnection, QpConnection } from '../services/ConnectionStore';
import { fetchAgentApproval } from '../services/AgentApproval';
import { loadChatApproval, saveChatApproval } from '../services/ChatApprovalPrefs';
import { setSessionApproval, setLoopCommand } from '../services/SessionControls';
import { OptionsSheet, SheetOption, optionOf } from './OptionsSheet';
import { SheetGate, moduleSheetOptions } from './SheetGate';

const MODE_MODEL: string = 'model';
const MODE_LOOP: string = 'loop';
const MODE_APPROVAL: string = 'approval';

class ModelChoice {
  value: string = '';   // providerId||model
  label: string = '';
}

/*
 * 行内按钮：一个圆角胶囊。
 * 图标统一用 QwenPaw 同款 lucide SVG（工程 media 资源）走 Image。
 * 注：SVG 走 media 而非 rawfile —— $rawfile 的资源经 @Prop 传给子组件后取不到内容
 * （真机实测：Image 节点根本不生成），$r 资源则正常。
 */
@Component
struct RuntimeChip {
  @Prop icon: Resource;
  @Prop label: Resource;
  @Prop value: string = '';
  @Prop tappable: boolean = false;
  onTap: () => void = (): void => {
  };
  private t(res: Resource): string {
    try {
      const host: common.Context = this.getUIContext().getHostContext() as common.Context;
      return host.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  build() {
    // Toggle(ToggleType.Button)：外观/行为与 Button 一致，但属全页面生效的沉浸材质组件。
    // isOn 固定 false（只借它的材质与交互反馈，不留选中态）；onChange 只用来触发点击动作。
    Toggle({ type: ToggleType.Button, isOn: false }) {
      Row({ space: 4 }) {
        Image(this.icon)
          .width(14)
          .height(14)
          .fillColor($r('app.color.text_secondary'))
          .draggable(false)
        Text(`${this.t(this.label)} ${this.value.length > 0 ? this.value : '—'}`)
          .fontSize(12)
          .fontColor($r('app.color.composer_label'))
          .maxLines(1)
      }
    }
    .padding({ left: 5, right: 5, top: 4, bottom: 4 })
    .borderRadius(12)
    // 透明底：材质自带玻璃观感（官方按钮示例即「透明底 + ImmersiveMaterial」）
    .backgroundColor(Color.Transparent)
    // 沉浸材质：THIN 与输入胶囊同档；实际效果随设备算力自适应（低算力仅保留一种样式）
    // interactive = 交互形变、lightEffect = 点光源反馈，二者替代组件默认按压态
    .systemMaterial(new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      interactive: true,
      lightEffect: {}
    }))
    // 材质启用交互形变 + 点光源后，组件默认按压态由材质反馈替代，无需自绘
    // Toggle 每次点按都会翻转内部开关态 → 若不抹掉选中底色，关掉菜单后按钮会留在"选中"色上，
    // 再点一次只是把选中取消（不触发动作）。两处一起收拾：
    //   ① selectedColor 透明 → 选中态不着色（观感完全由沉浸材质给）；
    //   ② onChange 不区分方向都触发动作 —— 芯片只在面板之外可见（面板打开时被遮住），
    //      不存在"再点一次代表关闭"的语义，故每次都按"打开"处理。
    .selectedColor(Color.Transparent)
    .enabled(this.tappable)
    .onChange((isOn: boolean): void => {
      this.onTap();
    })
  }
}

@Component
export struct SessionRuntimeBar {
  // 本会话标识：页面 aboutToAppear 里已就绪，首帧即为真值
  @Prop chatId: string = '';
  @Prop sessionId: string = '';
  @State modelName: string = '';
  @State modelProvider: string = '';   // 生效模型所属 provider（用于在面板里标出当前项）
  @State agentModelName: string = '';  // Agent 默认模型（会话覆盖时在面板标题里标出默认值）
  @State loopText: string = '';
  @State approval: string = '';
  @State busy: boolean = false;
  @State sheetShown: boolean = false;
  @State loopOptions: SheetOption[] = [];
  // 运行方式 id → 斜杠命令（GET /loops 的 slash_command；只读不参与渲染，故用普通 Map）
  private loopSlash: Map<string, string> = new Map<string, string>();
  @State sheetMode: string = '';
  // 本会话选择（对齐 7378：随发送生效，不写服务端）：循环取模式 id，审批取原始等级（空 = 跟随 Agent）
  @State pickedLoopId: string = '';
  @State pickedLoopName: string = '';
  @State pickedApproval: string = '';
  @State agentApproval: string = '';   // Agent 默认等级（审批面板「跟随 Agent」的说明用）
  private choices: ModelChoice[] = [];
  private gate: SheetGate = new SheetGate();
  private conn: QpConnection | null = null;
  // 会话级运行态轻查定时器（-1 = 未启动）
  private liveTimer: number = -1;

  aboutToAppear(): void {
    this.load();
  }

  private t(res: Resource): string {
    try {
      const host: common.Context = this.getUIContext().getHostContext() as common.Context;
      return host.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private async send(path: string, method: http.RequestMethod,
    body: string | null): Promise<http.HttpResponse> {
    const c: QpConnection | null = this.conn;
    if (c === null) {
      throw new Error(this.t($r('app.string.wb_not_connected')));
    }
    return doRequest(`${c.baseUrl}/api${path}`, method, body,
      c.token.length > 0 ? c.token : null, c.agentId);
  }

  private async load(): Promise<void> {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const c: QpConnection | null = await loadConnection(ctx);
    if (c === null) {
      return;
    }
    this.conn = c;
    try {
      const sessionModel: boolean = await this.readSessionModel();
      const act: http.HttpResponse = await this.send('/models/active', http.RequestMethod.GET, null);
      if (act.responseCode >= 200 && act.responseCode < 300) {
        const llm: Object = jsonOf(act)['active_llm'];
        if (llm !== undefined && llm !== null) {
          const rec: Record<string, Object> = llm as Record<string, Object>;
          const m: Object = rec['model'];
          this.agentModelName = typeof m === 'string' ? m as string : '';
          if (!sessionModel) {
            this.modelName = this.agentModelName;
            const p: Object = rec['provider_id'];
            this.modelProvider = typeof p === 'string' ? p as string : '';
          }
        }
      }
      await this.refreshLoopStatus();
      // 审批等级：默认值 = 服务端 Agent 级 approval_level（console 的 Agent 配置页同源），
      // 本会话若在本机选过则以会话覆盖为准（只影响这一个会话，见 ChatApprovalPrefs）
      await this.refreshAgentApproval();
      this.pickedApproval = await loadChatApproval(ctx, c.baseUrl, c.agentId, this.chatId);
      this.applyApprovalValue(this.pickedApproval);
      this.startLivePoll();
    } catch (e) {
      // 状态条属辅助信息：取不到保持「—」，不打断聊天
    }
  }

  aboutToDisappear(): void {
    if (this.liveTimer >= 0) {
      clearInterval(this.liveTimer);
      this.liveTimer = -1;
    }
  }

  // 会话生效模型（console 同口径）：GET /chats/{id}/thinking 回的就是本会话的 provider/model
  // （服务端把会话覆盖存在 chat.meta，见后端 chats/api.py set_session_model）。返回是否取到会话值。
  private async readSessionModel(): Promise<boolean> {
    if (this.chatId.length === 0) {
      return false;
    }
    const tv: http.HttpResponse = await this.send(
      `/chats/${encodeURIComponent(this.chatId)}/thinking`, http.RequestMethod.GET, null);
    if (tv.responseCode < 200 || tv.responseCode >= 300) {
      return false;
    }
    const rec: Record<string, Object> = jsonOf(tv);
    const m: Object = rec['model'];
    if (typeof m !== 'string' || (m as string).length === 0) {
      return false;
    }
    this.modelName = m as string;
    const p: Object = rec['provider_id'];
    this.modelProvider = typeof p === 'string' ? p as string : '';
    return true;
  }

  // 会话循环状态（服务端按 (chat_id, session_id) 记）：空闲显示运行方式名，运行/暂停显示状态。
  private async refreshLoopStatus(): Promise<void> {
    const sid: string = this.sessionId.length > 0 ? this.sessionId : this.chatId;
    const st: http.HttpResponse = await this.send(
      `/loops/status?chat_id=${encodeURIComponent(this.chatId)}&session_id=${encodeURIComponent(sid)}`,
      http.RequestMethod.GET, null);
    if (st.responseCode < 200 || st.responseCode >= 300) {
      return;
    }
    const rec: Record<string, Object> = jsonOf(st);
    const state: Object = rec['state'];
    const stateText: string = typeof state === 'string' ? state as string : '';
    const mode: Object = rec['mode'];
    let text: string = '';
    if (stateText.trim().toLowerCase() === 'idle') {
      // 空闲：显示所选运行方式的名字（对齐 7378 loopName(selectedLoopMode)）
      const ls: http.HttpResponse = await this.send('/loops', http.RequestMethod.GET, null);
      if (ls.responseCode >= 200 && ls.responseCode < 300) {
        const arr: Object = jsonOf(ls)['loops'] !== undefined ? jsonOf(ls)['loops'] : jsonOf(ls);
        if (Array.isArray(arr)) {
          const list: Object[] = arr as Object[];
          if (list.length > 0) {
            const first: Record<string, Object> = list[0] as Record<string, Object>;
            const nm: Object = first['name'];
            const id: Object = first['id'];
            text = typeof nm === 'string' && (nm as string).length > 0 ? nm as string
              : (typeof id === 'string' ? id as string : '');
          }
        }
      }
      if (text.length === 0 && mode !== undefined && mode !== null) {
        const mr: Record<string, Object> = mode as Record<string, Object>;
        const nm2: Object = mr['name'];
        if (typeof nm2 === 'string') {
          text = nm2 as string;
        }
      }
    } else {
      // 运行中/暂停：显示状态标签；有模式名时优先模式名（对齐 7378 的 loopRunning 分支）
      text = this.loopStateLabelOf(stateText);
      if (mode !== undefined && mode !== null) {
        const mr2: Record<string, Object> = mode as Record<string, Object>;
        const nm3: Object = mr2['name'];
        if (typeof nm3 === 'string' && (nm3 as string).length > 0) {
          text = nm3 as string;
        }
      }
    }
    this.loopText = text;
  }

  // 会话级运行态的定时轻查（4s）：循环状态与会话模型都是服务端按会话记的，别处（console / 另一台
  // 设备）起停循环或改会话模型后，本页不重进也要跟着变 —— 只查这两项，不重取模型目录与运行配置。
  private startLivePoll(): void {
    if (this.liveTimer >= 0 || this.conn === null) {
      return;
    }
    this.liveTimer = setInterval((): void => {
      this.refreshLive();
    }, 4000);
  }

  private async refreshLive(): Promise<void> {
    if (this.conn === null) {
      return;
    }
    try {
      await this.refreshLoopStatus();
      await this.readSessionModel();
      // 审批等级也是服务端状态：面板没开着时跟着刷新（console 侧改过这里也要跟上）
      if (!this.sheetShown) {
        await this.refreshAgentApproval();
      }
    } catch (e) {
      // 轻查失败不影响界面
    }
  }

  // 读服务端 Agent 审批等级（'' = 服务端未给值）：它是没有会话覆盖时的默认值。
  // 服务端值变化（console 的 Agent 配置页改过）→ 没有会话覆盖时显示与发送都跟着变
  private async refreshAgentApproval(): Promise<void> {
    const c: QpConnection | null = this.conn;
    if (c === null) {
      return;
    }
    try {
      this.agentApproval = await fetchAgentApproval(c.baseUrl, c.token, c.agentId);
      this.applyApprovalValue(this.pickedApproval);
    } catch (e) {
      // 取不到保持原显示
    }
  }

  // 生效审批等级 = 本会话覆盖（优先）?? 服务端 Agent 默认值；'' = 服务端也没给值
  private effectiveApproval(): string {
    return this.pickedApproval.length > 0 ? this.pickedApproval : this.agentApproval;
  }

  // 把「本会话覆盖」落到显示与发送链路（对齐 console：sessionLevel ?? runningConfigApprovalLevel，
  // 而 request_context.approval_level 用生效值）
  private applyApprovalValue(override: string): void {
    const effective: string = this.effectiveApproval();
    setSessionApproval(effective);
    this.approval = effective.length > 0 ? this.approvalLabelOf(effective) : '';
  }

  // 本会话选择：只改这一个会话（本机按会话落盘，见 ChatApprovalPrefs），不写服务端 Agent 默认值
  private pickApproval(level: string): void {
    this.pickedApproval = level;
    this.applyApprovalValue(level);
    const c: QpConnection | null = this.conn;
    if (c !== null) {
      saveChatApproval(this.getUIContext().getHostContext() as common.Context,
        c.baseUrl, c.agentId, this.chatId, level);
    }
  }

  // 审批等级显示映射（对齐 7378 SessionRuntimeControls 的 APPROVAL_OPTIONS 标签）；
  // 未知值原样透出，避免凭空造标签。
  private approvalLabelOf(raw: string): string {
    const up: string = raw.trim().toUpperCase();
    if (up === 'STRICT') {
      return this.t($r('app.string.chat_approval_strict'));
    }
    if (up === 'SMART') {
      return this.t($r('app.string.chat_approval_smart'));
    }
    if (up === 'AUTO') {
      return this.t($r('app.string.chat_approval_auto'));
    }
    if (up === 'OFF') {
      return this.t($r('app.string.chat_approval_off'));
    }
    return raw;
  }

  // 循环运行态显示映射（7378 loopStateLabel 的同位做法）
  private loopStateLabelOf(state: string): string {
    const st: string = state.trim().toLowerCase();
    if (st === 'running') {
      return this.t($r('app.string.chat_loop_running'));
    }
    if (st === 'paused') {
      return this.t($r('app.string.chat_loop_paused'));
    }
    return state;
  }

  private stringArray(v: Object): string[] {
    const out: string[] = [];
    if (v === undefined || v === null || !Array.isArray(v)) {
      return out;
    }
    for (const s of v as Object[]) {
      if (typeof s === 'string') {
        out.push(s as string);
      }
    }
    return out;
  }

  // provider 是否可用（对齐 7378 sessionControlsModel.selectableProviders）：
  // 自定义/本地/免密钥的看 base_url 是否配置，其余看 api_key 或已 OAuth 授权；
  // 未配置的 provider 一个模型都不列。
  private isConfigured(r: Record<string, Object>): boolean {
    const hasBaseUrl: boolean = (() => {
      const b: Object = r['base_url'];
      return typeof b === 'string' && (b as string).trim().length > 0;
    })();
    if (r['is_custom'] === true || r['is_local'] === true || r['require_api_key'] === false) {
      return hasBaseUrl;
    }
    const key: Object = r['api_key'];
    return (typeof key === 'string' && (key as string).length > 0) || r['oauth_connected'] === true;
  }

  // 可选模型清单（对齐 7378）：models + extra_models 合并 → 去掉 hidden_model_ids →
  // 按 id 去重 → 丢弃空 id。
  private async loadChoices(): Promise<void> {
    const list: ModelChoice[] = [];
    const resp: http.HttpResponse = await this.send('/models', http.RequestMethod.GET, null);
    if (resp.responseCode >= 200 && resp.responseCode < 300) {
      for (const item of jsonArrayOf(resp)) {
        const r: Record<string, Object> = item as Record<string, Object>;
        const pid: Object = r['id'];
        if (typeof pid !== 'string' || (pid as string).length === 0 || !this.isConfigured(r)) {
          continue;
        }
        const pname: Object = r['name'];
        const pnameText: string = typeof pname === 'string' && (pname as string).length > 0
          ? pname as string : pid as string;
        const hidden: string[] = this.stringArray(r['hidden_model_ids']);
        const ids: string[] = [];
        const names: string[] = [];
        for (const key of ['models', 'extra_models']) {
          const arr: Object = r[key];
          if (arr === undefined || arr === null || !Array.isArray(arr)) {
            continue;
          }
          for (const m of arr as Object[]) {
            const rec: Record<string, Object> = m as Record<string, Object>;
            const id: Object = rec['id'];
            if (typeof id !== 'string' || (id as string).length === 0
              || hidden.includes(id as string) || ids.includes(id as string)) {
              continue;
            }
            const nm: Object = rec['name'];
            ids.push(id as string);
            names.push(typeof nm === 'string' && (nm as string).length > 0 ? nm as string : id as string);
          }
        }
        for (let i = 0; i < ids.length; i++) {
          const c: ModelChoice = new ModelChoice();
          c.value = `${pid as string}||${ids[i]}`;
          c.label = `${pnameText} · ${names[i]}`;
          list.push(c);
        }
      }
    }
    this.choices = list;
  }

  private openModel(): void {
    this.sheetMode = MODE_MODEL;
    this.loadChoices().then((): void => {
      if (this.gate.request()) {
        this.sheetShown = true;
      }
    }).catch((e: Object): void => {
      this.toast(`${this.t($r('app.string.chat_runtime_switch_failed'))}：${e as string}`);
    });
  }

  // 运行方式面板：GET /loops（对齐 7378 面板标题「运行方式 / 选择下一轮如何推进任务」）
  private async openLoop(): Promise<void> {
    this.sheetMode = MODE_LOOP;
    try {
      const resp: http.HttpResponse = await this.send('/loops', http.RequestMethod.GET, null);
      const out: SheetOption[] = [];
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        const d: Record<string, Object> = jsonOf(resp);
        const arr: Object = d['loops'] !== undefined ? d['loops'] : (resp.result as Object);
        if (Array.isArray(arr)) {
          for (const it of arr as Object[]) {
            const r: Record<string, Object> = it as Record<string, Object>;
            const id: Object = r['id'];
            if (typeof id !== 'string' || (id as string).length === 0) {
              continue;
            }
            const nm: Object = r['name'];
            const slash: Object = r['slash_command'];
            this.loopSlash.set(id as string, typeof slash === 'string' ? slash as string : '');
            out.push(optionOf(id as string,
              typeof nm === 'string' && (nm as string).length > 0 ? nm as string : id as string));
          }
        }
      }
      this.loopOptions = out;
    } catch (e) {
      this.loopOptions = [];
    }
    if (this.gate.request()) {
      this.sheetShown = true;
    }
  }

  // 审批面板：跟随 Agent + 四级（对齐 7378 APPROVAL_OPTIONS 与「Agent 默认：…」说明）
  private openApproval(): void {
    this.sheetMode = MODE_APPROVAL;
    if (this.gate.request()) {
      this.sheetShown = true;
    }
  }

  // 审批面板：「跟随 Agent（<服务端默认值>）」+ 四级。选前四项 = 本会话覆盖（只影响这一个会话）；
  // 选「跟随 Agent」= 清掉覆盖、回到服务端 Agent 默认值（与 7378 会话面板同构）
  private approvalChoices(): SheetOption[] {
    const fallback: string = this.agentApproval.length > 0
      ? `${this.t($r('app.string.chat_runtime_follow_agent'))}（${this.t($r('app.string.chat_runtime_agent_default'))}：${this.approvalLabelOf(this.agentApproval)}）`
      : this.t($r('app.string.chat_runtime_follow_agent'));
    return [
      optionOf('', fallback),
      optionOf('STRICT', this.t($r('app.string.chat_approval_strict'))),
      optionOf('SMART', this.t($r('app.string.chat_approval_smart'))),
      optionOf('AUTO', this.t($r('app.string.chat_approval_auto'))),
      optionOf('OFF', this.t($r('app.string.chat_approval_off')))
    ];
  }

  private closeSheet(): void {
    this.gate.beginClose();
    this.sheetShown = false;
  }

  private options(): SheetOption[] {
    const out: SheetOption[] = [];
    for (const c of this.choices) {
      out.push(optionOf(c.value, c.label));
    }
    return out;
  }

  private async onPick(value: string): Promise<void> {
    const parts: string[] = value.split('||');
    const c: QpConnection | null = this.conn;
    if (parts.length !== 2 || c === null || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const body: Record<string, Object> = {};
      body['provider_id'] = parts[0];
      body['model'] = parts[1];
      // 会话级写入（console 同口径）：PUT /chats/{id}/model 只改本会话，不动 Agent 默认模型
      //（此前写 /models/active scope=agent，等于把整个 Agent 的模型换掉）
      const resp: http.HttpResponse = await this.send(
        `/chats/${encodeURIComponent(this.chatId)}/model`, http.RequestMethod.PUT,
        JSON.stringify(body));
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      this.modelProvider = parts[0];
      this.modelName = parts[1];
      await this.load();
    } catch (e) {
      this.toast(`${this.t($r('app.string.chat_runtime_switch_failed'))}：${(e as Error).message}`);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      // 横向滚动：控制项多时不换行、不挤压（7378 同为横向可滚的控制条）
      Scroll() {
        Row({ space: 4 }) {
          RuntimeChip({
            icon: $r('app.media.model_llm'),
            label: $r('app.string.chat_runtime_model'),
            value: this.modelName,
            tappable: !this.busy,
            onTap: (): void => {
              this.openModel();
            }
          })
          RuntimeChip({
            icon: $r('app.media.refresh_cw'),
            label: $r('app.string.chat_runtime_loop'),
            value: this.loopText,
            tappable: !this.busy,
            onTap: (): void => {
              this.openLoop();
            }
          })
          RuntimeChip({
            icon: $r('app.media.shield_check'),
            label: $r('app.string.chat_runtime_approval'),
            value: this.approval,
            tappable: !this.busy,
            onTap: (): void => {
              this.openApproval();
            }
          })
        }
        .padding({ left: 3, right: 3 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      // 按压/拖动的交互形变会超出按钮自身范围：滚动容器默认裁切子节点 →
      // 关掉裁切并给上下留出形变空间，拖动时不再被切边
      .clip(false)
      .padding({ top: 4, bottom: 4 })
    }
    .width('100%')
    .bindSheet(this.sheetShown, this.sheetContent(),
      moduleSheetOptions(560, this.gate, (v: boolean): void => {
        this.sheetShown = v;
      }))
  }

  @Builder
  sheetContent() {
    Column() {
      if (this.sheetMode === MODE_LOOP) {
        OptionsSheet({
          title: this.t($r('app.string.chat_runtime_loop_title')),
          options: this.loopOptions,
          current: this.pickedLoopId,
          confirmPick: true,
          onConfirm: (v: string): void => {
            this.pickedLoopId = v;
            for (const o of this.loopOptions) {
              if (o.value === v) {
                this.pickedLoopName = o.label;
              }
            }
            if (this.pickedLoopName.length > 0) {
              this.loopText = this.pickedLoopName;
            }
            // 一次性：选中只对下一条生效（对齐 7378 beginSubmission）
            const cmd: string | undefined = this.loopSlash.get(v);
            setLoopCommand(cmd !== undefined ? cmd : '');
            this.closeSheet();
          },
          onClose: (): void => {
            this.closeSheet();
          }
        })
      } else if (this.sheetMode === MODE_APPROVAL) {
        OptionsSheet({
          title: this.t($r('app.string.chat_runtime_approval_title')),
          options: this.approvalChoices(),
          current: this.pickedApproval,
          confirmPick: true,
          onConfirm: (v: string): void => {
            // 只改本会话（本机落盘 + 发送值）；面板由 OptionsSheet 的 onClose 收起，这里不再关闭，
            // 避免"关闭动画结束后又被置位"把闸门卡在回退态（见 SheetGate 的宽限期说明）
            this.pickApproval(v);
          },
          onClose: (): void => {
            this.closeSheet();
          }
        })
      } else if (this.sheetMode === MODE_MODEL) {
        OptionsSheet({
          title: this.agentModelName.length > 0 && this.agentModelName !== this.modelName
            ? `${this.t($r('app.string.chat_runtime_pick_model'))}（${this.t($r('app.string.chat_runtime_agent_default'))}：${this.agentModelName}）`
            : this.t($r('app.string.chat_runtime_pick_model')),
          options: this.options(),
          // 当前生效项打勾（与 SheetOption.value 同形：providerId||modelId）
          current: `${this.modelProvider}||${this.modelName}`,
          // 选择模型：列表里点选打勾 → 点「确定」才切换（取消交给右上角 ✕ / 下拉）
          confirmPick: true,
          onConfirm: (v: string): void => {
            this.onPick(v);
          },
          onClose: (): void => {
            this.closeSheet();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
