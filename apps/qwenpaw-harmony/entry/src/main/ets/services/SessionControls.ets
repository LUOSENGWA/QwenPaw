/*
 * 会话运行控制的本机选择（对齐 PR #7378：审批等级这类选择随「发送」生效，不改服务端 Agent 配置）。
 * 为什么用模块级单例：运行条挂在 Tabs 的 tabBar builder 内，该子树只构建一次、父组件状态传不进去
 * （见 harmony-arkui-tabbar-builder-runs-once），故由运行条写入、发送链路在发送时读取。
 */

let approvalLevel: string = '';   // 空串 = 跟随 Agent（即不发 request_context）

export function setSessionApproval(value: string): void {
  approvalLevel = value;
}

export function sessionApproval(): string {
  return approvalLevel;
}

let loopCommand: string = '';   // 一次性：选中后只对下一条消息生效（对齐 7378 beginSubmission 的 one-shot）

export function setLoopCommand(command: string): void {
  loopCommand = command;
}

/** 取出并复位（一次性）；无选择时返回空串。 */
export function takeLoopCommand(): string {
  const c: string = loopCommand;
  loopCommand = '';
  return c;
}

/**
 * 对齐 7378 features/chat/sessionControlsModel.ts 的 applyLoopModeCommand：
 * 无命令 → 原样；用户已写斜杠命令 → 不覆盖；否则前置 "/<command> "。
 */
export function applyLoopCommand(text: string, command: string): string {
  const cmd: string = command.trim();
  if (cmd.length === 0) {
    return text;
  }
  if (text.trimStart().startsWith('/')) {
    return text;
  }
  return `/${cmd} ${text}`;
}
