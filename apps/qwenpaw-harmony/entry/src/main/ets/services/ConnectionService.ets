/*
 * LAN 直连服务 —— 对齐 PR #7378 src/api/client.ts 的直连链路：
 *   1. 有配对码：POST {base}/api/auth/pairing/redeem {ticket} → {token, username, mode?}
 *   2. GET {base}/api/auth/status → {enabled, has_users}
 *      - 未开账号体系（enabled=false）且无 token → 开放模式直连
 *      - 有 token → GET {base}/api/auth/verify（Bearer）
 *      - 开了账号体系且无 ticket → 拒绝
 *   3. 探测 GET {base}/api/agents → {agents: [...]}
 * 超时语义与 connectionAttempt.ts 一致：10s，127.0.0.1 专项提示。
 */

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { QpConnection } from './ConnectionStore';
import { normalizeBaseUrl, hostOf } from './PairingModel';
import { t, tf } from './I18n';

const CONNECT_TIMEOUT_MS: number = 10000;

export class ConnectError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConnectError';
  }
}

export interface ConnectOutcome {
  connection: QpConnection;
  agentCount: number;
  agentNames: string[];
  agentIds: string[];
  openMode: boolean;
}

export function doRequest(url: string, method: http.RequestMethod, body: string | null,
  token: string | null, agentId: string): Promise<http.HttpResponse> {
  const req: http.HttpRequest = http.createHttp();
  const header: Record<string, Object> = {
    'Content-Type': 'application/json',
    'Accept': 'application/json'
  };
  if (token !== null && token.length > 0) {
    header['Authorization'] = `Bearer ${token}`;
  }
  // 对齐 PR #7378 client.ts headers()：所有 /api 请求携带当前智能体（会话/审批按 agent 隔离）
  if (agentId.length > 0) {
    header['X-Agent-Id'] = agentId;
  }
  const options: http.HttpRequestOptions = {
    method: method,
    header: header,
    connectTimeout: CONNECT_TIMEOUT_MS,
    readTimeout: CONNECT_TIMEOUT_MS,
    expectDataType: http.HttpDataType.STRING
  };
  if (body !== null) {
    options.extraData = body;
  }
  const promise: Promise<http.HttpResponse> = req.request(url, options);
  promise.then(() => req.destroy()).catch(() => req.destroy());
  return promise;
}

export function jsonOf(response: http.HttpResponse): Record<string, Object> {
  const result: Object = response.result;
  if (typeof result !== 'string') {
    throw new ConnectError(t($r('app.string.conn_err_non_json')));
  }
  try {
    return JSON.parse(result) as Record<string, Object>;
  } catch (e) {
    throw new ConnectError(t($r('app.string.conn_err_non_json')));
  }
}

// 顶层返回数组的端点（/tools、/skills、/workspace/git/log 等）：jsonOf 是对象口径，数组需单独解析
export function jsonArrayOf(response: http.HttpResponse): Object[] {
  const result: Object = response.result;
  if (typeof result !== 'string') {
    return [];
  }
  try {
    const parsed: Object = JSON.parse(result as string);
    return Array.isArray(parsed) ? parsed as Object[] : [];
  } catch (e) {
    return [];
  }
}

export function timeoutHint(baseUrl: string): string {
  const host: string = hostOf(baseUrl);
  if (host === '127.0.0.1' || host === 'localhost' || host === '[::1]' || host === '::1') {
    return t($r('app.string.conn_err_timeout_localhost'));
  }
  return t($r('app.string.conn_err_timeout'));
}

export function describeConnectError(baseUrl: string, e: Error): string {
  if (e instanceof ConnectError) {
    return e.message;
  }
  const msg: string = e.message ? e.message : String(e);
  const code: number = (e as BusinessError).code !== undefined ? (e as BusinessError).code : -1;
  if (code === 2300006 || code === 2300005 || code === 2300004 || code === 2300003 ||
    /time\s?out|timed out/i.test(msg)) {
    return timeoutHint(baseUrl);
  }
  if (code >= 2300000 && code < 2400000) {
    return tf($r('app.string.conn_err_network'), code);
  }
  if (/refused|ECONNREFUSED|no route|unreachable|EHOSTUNREACH/i.test(msg)) {
    return tf($r('app.string.conn_err_unreachable'), baseUrl);
  }
  return tf($r('app.string.conn_err_failed'), msg);
}

// 账号体系开关（GET /api/auth/status）
async function fetchAuthEnabled(baseUrl: string): Promise<boolean> {
  const statusResp: http.HttpResponse = await doRequest(
    `${baseUrl}/api/auth/status`, http.RequestMethod.GET, null, null, 'default');
  if (statusResp.responseCode !== 200) {
    throw new ConnectError(tf($r('app.string.conn_err_http'), statusResp.responseCode));
  }
  return jsonOf(statusResp)['enabled'] === true;
}

// 票据校验（GET /api/auth/verify，Bearer）
async function verifyToken(baseUrl: string, token: string, hint: string): Promise<void> {
  const verifyResp: http.HttpResponse = await doRequest(
    `${baseUrl}/api/auth/verify`, http.RequestMethod.GET, null, token, 'default');
  if (verifyResp.responseCode !== 200) {
    throw new ConnectError(tf($r('app.string.conn_err_verify'), verifyResp.responseCode, hint));
  }
}

interface AgentProbe {
  agentCount: number;
  agentNames: string[];
  agentIds: string[];
}

// 智能体探测（GET /api/agents）：失败不阻断连接（可能服务版本差异）
async function probeAgents(baseUrl: string, token: string): Promise<AgentProbe> {
  const probe: AgentProbe = { agentCount: 0, agentNames: [], agentIds: [] };
  try {
    const agentsResp: http.HttpResponse = await doRequest(
      `${baseUrl}/api/agents`, http.RequestMethod.GET, null,
      token.length > 0 ? token : null, 'default');
    if (agentsResp.responseCode === 200) {
      const data: Record<string, Object> = jsonOf(agentsResp);
      const arr: Object = data['agents'];
      if (Array.isArray(arr)) {
        const items: Object[] = arr as Object[];
        probe.agentCount = items.length;
        for (const item of items) {
          const a: Record<string, Object> = item as Record<string, Object>;
          const aid: string = typeof a['id'] === 'string' ? a['id'] as string : '';
          probe.agentIds.push(aid);
          if (typeof a['name'] === 'string' && (a['name'] as string).length > 0) {
            probe.agentNames.push(a['name'] as string);
          } else {
            probe.agentNames.push(aid);
          }
        }
      }
    }
  } catch (e) {
    // 见上：探测失败不阻断
  }
  return probe;
}

// preferredAgentId：调用方已知的"用户选中的智能体"（自动重连/重连同一地址时传入）。
// 此前写死 'default' → 每次启动自动重连都会把用户的选择覆盖回 default。选中的 id 已不存在时（被删）才回落 'default'。
export async function connectToQwenPaw(baseUrlRaw: string, ticketRaw: string,
  preferredAgentId: string = ''): Promise<ConnectOutcome> {
  const baseUrl: string = normalizeBaseUrl(baseUrlRaw);
  const ticket: string = ticketRaw.trim();

  let token: string = '';
  let username: string = '';
  let serverMode: string = '';
  if (ticket.length > 0) {
    const redeemBody: Record<string, string> = { 'ticket': ticket };
    const redeemResp: http.HttpResponse = await doRequest(
      `${baseUrl}/api/auth/pairing/redeem`, http.RequestMethod.POST,
      JSON.stringify(redeemBody), null, 'default');
    if (redeemResp.responseCode !== 200) {
      throw new ConnectError(tf($r('app.string.conn_err_redeem'), redeemResp.responseCode));
    }
    const data: Record<string, Object> = jsonOf(redeemResp);
    token = typeof data['token'] === 'string' ? data['token'] as string : '';
    username = typeof data['username'] === 'string' ? data['username'] as string : '';
    serverMode = data['mode'] === 'hub' ? 'hub' : '';
    if (token.length === 0) {
      throw new ConnectError(t($r('app.string.conn_err_no_ticket')));
    }
  }

  const authEnabled: boolean = await fetchAuthEnabled(baseUrl);
  if (token.length > 0) {
    await verifyToken(baseUrl, token, t($r('app.string.conn_hint_code_invalid')));
  } else if (authEnabled) {
    throw new ConnectError(t($r('app.string.conn_err_account_required')));
  }
  // else：开放模式（无账号体系且无票据）直连

  const connection: QpConnection = {
    baseUrl: baseUrl,
    token: token,
    username: username,
    agentId: 'default',
    source: 'private',
    serverMode: serverMode
  };
  const probe: AgentProbe = await probeAgents(baseUrl, token);

  // 保留用户选中的智能体：探测成功且该 id 仍在列则沿用，否则（探测失败/已删除）回落 default
  const wanted: string = preferredAgentId.trim();
  const stillThere: boolean = probe.agentIds.length === 0 || probe.agentIds.indexOf(wanted) >= 0;
  connection.agentId = wanted.length > 0 && stillThere ? wanted : 'default';

  const outcome: ConnectOutcome = {
    connection: connection,
    agentCount: probe.agentCount,
    agentNames: probe.agentNames,
    agentIds: probe.agentIds,
    openMode: token.length === 0 && !authEnabled
  };
  return outcome;
}

// 已落盘连接（含 token）复核 —— 切换连接 / 扫码配对回跳时用：不重新兑换配对码，
// 直接校验票据并探测智能体（旧实现回落成"用空配对码重连"，遇到开账号体系的服务必然失败）。
export async function verifyConnection(conn: QpConnection): Promise<ConnectOutcome> {
  const baseUrl: string = conn.baseUrl;
  const token: string = conn.token;
  const authEnabled: boolean = await fetchAuthEnabled(baseUrl);
  if (token.length > 0) {
    await verifyToken(baseUrl, token, t($r('app.string.conn_hint_maybe_expired')));
  } else if (authEnabled) {
    throw new ConnectError(t($r('app.string.conn_err_account_required_again')));
  }
  const probe: AgentProbe = await probeAgents(baseUrl, token);
  const outcome: ConnectOutcome = {
    connection: conn,
    agentCount: probe.agentCount,
    agentNames: probe.agentNames,
    agentIds: probe.agentIds,
    openMode: token.length === 0 && !authEnabled
  };
  return outcome;
}
