/*
 * 会话详情服务 —— 历史 + 流式对话（对齐 PR #7378 apps/qwenpaw-mobile/src/api/client.ts
 * getChat / streamChat / stopChat）：
 *   GET  {base}/api/chats/{id}                      → { messages: WireMessage[], status }
 *   POST {base}/api/console/chat（stream: true）    → SSE 流（SseParser 增量解析）
 *   POST {base}/api/console/chat/stop?chat_id={id}  → 停止当前轮次
 * 传输层 = http.requestInStream + on('dataReceive')/on('dataEnd')（@ohos.net.http 流式接口）。
 */

import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { doRequest, jsonOf, ConnectError } from './ConnectionService';
import { SseParser, SseEvent, StreamDelta, StreamEventClassifier, streamError } from './SseParser';

// 会话详情关闭事件：会话列表据此重载（对齐 PR 列表页离开详情后刷新的行为）
export const CHAT_CLOSED_EVENT: string = 'qp_chat_closed';

export interface ChatMessage {
  id: string;
  role: string;   // user / assistant / tool / system
  kind: string;   // message / reasoning / tool
  text: string;
}

export interface ChatHistory {
  messages: ChatMessage[];
  running: boolean;
}

// 会话详情路由参数（ConnectPanel → 'chat' 路由）
export interface ChatRouteParam {
  chatId: string;
  chatName: string;
  sessionId: string;     // 发送用的 session_id（对齐 RN：chat.session_id，与 chatId 可能不同）
}

// 流式请求体（对齐 PR /console/chat 的 input 结构）
export interface ChatInputPart {
  type: string;              // text / image / video / audio / file
  text?: string;
  image_url?: string;
  video_url?: string;
  file_url?: string;
  file_name?: string;
  data?: string;
}

interface ChatInputMessage {
  role: string;
  content: ChatInputPart[];
}

interface ChatStreamRequest {
  input: ChatInputMessage[];
  session_id: string;
  user_id: string;
  channel: string;
  stream: boolean;
}

interface DecodeStreamOptions {
  stream: boolean;
}

function strOf(rec: Record<string, Object>, key: string): string {
  const v: Object = rec[key];
  return typeof v === 'string' ? v as string : '';
}

// content: string | ContentItem[] | object → 纯文本（只取 text 类分片，其余类型暂不渲染）
function textOfContent(content: Object): string {
  if (typeof content === 'string') {
    return content as string;
  }
  if (!Array.isArray(content)) {
    return '';
  }
  let out: string = '';
  const parts: Object[] = content as Object[];
  for (const part of parts) {
    const rec: Record<string, Object> = part as Record<string, Object>;
    const t: Object = rec['text'];
    if (typeof t === 'string') {
      out += t as string;
    }
  }
  return out;
}

// 消息级判定 —— 逐条对齐 RN api/messages.ts:56-71（toDisplayMessage）：
//   type === 'reasoning'                      → 'reasoning'
//   type 属工具类型（含 tool 字样）或 role === 'tool' → 'tool'
//   其余                                       → 'message'
// 之前漏了 role === 'tool' 一条，导致工具消息落进普通气泡（"一大坨字"）。
function kindOfMessage(type: string, role: string): string {
  if (type === 'reasoning') {
    return 'reasoning';
  }
  if (type.toLowerCase().indexOf('tool') >= 0 || role === 'tool') {
    return 'tool';
  }
  return 'message';
}

function messageOf(rec: Record<string, Object>): ChatMessage {
  const type: string = strOf(rec, 'type');
  const role: string = strOf(rec, 'role');
  return {
    id: strOf(rec, 'id'),
    role: role,
    kind: kindOfMessage(type, role),
    text: textOfContent(rec['content'])
  };
}

// 分片类型归一：reasoning/thinking → 'reasoning'；含 tool 的（tool_use/tool_result…）→ 'tool'；
// 其余（text/image/video/audio/file）不额外成条（文本仍由 messageOf 取，媒体分片一期不渲染）
function partKindOf(type: string): string {
  const t: string = type.toLowerCase();
  if (t.indexOf('reasoning') >= 0 || t === 'thinking') {
    return 'reasoning';
  }
  if (t.indexOf('tool') >= 0) {
    return 'tool';
  }
  return '';
}

function jsonText(v: Object): string {
  if (v === undefined || v === null) {
    return '';
  }
  if (typeof v === 'string') {
    return v as string;
  }
  try {
    return JSON.stringify(v);
  } catch (e) {
    return '';
  }
}

function partTextOf(p: Record<string, Object>): string {
  const t: Object = p['text'];
  if (typeof t === 'string' && (t as string).trim().length > 0) {
    return t as string;
  }
  return '';
}

// 工具调用的可读文本（对齐 RN api/messages.ts:163-183：载荷在 content[].data 里，
// 取 data.name / data.arguments / data.output；无 data 时回落分片上的 name/input/tool_name）
function toolTextOf(p: Record<string, Object>): string {
  let name: string = '';
  let args: string = '';
  let output: string = '';
  const dObj: Object = p['data'];
  if (dObj !== undefined && dObj !== null && !Array.isArray(dObj)) {
    const d: Record<string, Object> = dObj as Record<string, Object>;
    name = strOf(d, 'name');
    args = jsonText(d['arguments']);
    output = jsonText(d['output']);
  }
  if (name.length === 0) {
    name = strOf(p, 'name').length > 0 ? strOf(p, 'name') : strOf(p, 'tool_name');
  }
  if (args.length === 0) {
    args = jsonText(p['input']);
  }
  const head: string = name.length > 0 ? name : '工具调用';
  if (args.length > 0) {
    return `${head} ${args}`.substring(0, 400);
  }
  if (output.length > 0) {
    return `${head} → ${output}`.substring(0, 400);
  }
  return head;
}

// 消息/分片的展示文本：工具类走 toolTextOf，其余走 text
function partDisplayText(kind: string, p: Record<string, Object>): string {
  if (kind === 'tool') {
    return toolTextOf(p);
  }
  return partTextOf(p);
}

// 消息级 kind 为 reasoning/tool 但正文为空时，从 content 分片里凑出可读文本
function contentTextOf(rec: Record<string, Object>, kind: string): string {
  const content: Object = rec['content'];
  if (!Array.isArray(content)) {
    return '';
  }
  const parts: Object[] = content as Object[];
  let out: string = '';
  for (const p of parts) {
    const pr: Record<string, Object> = p as Record<string, Object>;
    const t: string = partDisplayText(kind, pr);
    if (t.length > 0) {
      out = out.length > 0 ? `${out} ${t}` : t;
    }
    if (out.length >= 400) {
      break;
    }
  }
  return out.substring(0, 400);
}

// 消息的 content 分片里，reasoning / tool 各自成条（对齐 RN api/messages.ts 的分片映射思路）
function extraPartsOf(rec: Record<string, Object>, msgId: string, role: string): ChatMessage[] {
  const content: Object = rec['content'];
  if (!Array.isArray(content)) {
    return [];
  }
  const out: ChatMessage[] = [];
  const parts: Object[] = content as Object[];
  let i: number = 0;
  for (const p of parts) {
    const pr: Record<string, Object> = p as Record<string, Object>;
    let kind: string = partKindOf(strOf(pr, 'type'));
    if (kind.length === 0 && pr['data'] !== undefined && pr['data'] !== null) {
      kind = 'tool';   // 带 data 对象的分片 = 工具调用载荷（RN 同款判定）
    }
    if (kind.length > 0) {
      const text: string = partDisplayText(kind, pr);
      if (text.length > 0) {
        const m: ChatMessage = { id: `${msgId}_p${i}`, role: role, kind: kind, text: text };
        out.push(m);
      }
    }
    i++;
  }
  return out;
}

export async function fetchChatMessages(baseUrl: string, token: string, agentId: string,
  chatId: string): Promise<ChatHistory> {
  const resp: http.HttpResponse = await doRequest(
    `${baseUrl}/api/chats/${encodeURIComponent(chatId)}`, http.RequestMethod.GET, null,
    token.length > 0 ? token : null, agentId);
  if (resp.responseCode === 401 || resp.responseCode === 403) {
    throw new ConnectError(`票据已失效（HTTP ${resp.responseCode}），请重新连接。`);
  }
  if (resp.responseCode !== 200) {
    throw new ConnectError(`读取会话失败（HTTP ${resp.responseCode}）。`);
  }
  const data: Record<string, Object> = jsonOf(resp);
  const arr: Object = data['messages'];
  const out: ChatMessage[] = [];
  if (Array.isArray(arr)) {
    const items: Object[] = arr as Object[];
    for (const item of items) {
      const rec: Record<string, Object> = item as Record<string, Object>;
      const m: ChatMessage = messageOf(rec);
      if (m.text.length > 0) {
        out.push(m);
      }
      for (const e of extraPartsOf(rec, m.id, m.role)) {
        out.push(e);
      }
      const mkind: string = partKindOf(strOf(rec, 'type'));
      if (mkind.length > 0 && m.text.length === 0) {
        const t: string = contentTextOf(rec, mkind);
        if (t.length > 0) {
          const mm: ChatMessage = {
            id: m.id.length > 0 ? m.id : `msg_${out.length}`,
            role: m.role,
            kind: mkind,
            text: t
          };
          out.push(mm);
        }
      }
    }
  }
  return { messages: out, running: strOf(data, 'status') === 'running' };
}

export interface ChatStreamHandle {
  stop(): void;
}

class ChatStream implements ChatStreamHandle {
  private readonly onStop: () => void;

  constructor(onStop: () => void) {
    this.onStop = onStop;
  }

  stop(): void {
    this.onStop();
  }
}

// 发起一轮对话并流式接收增量；parts = 本轮用户消息的 content 分片（文本 + 附件，对齐 RN submit 的 content 数组）；
// onDone 至多回调一次（error 为 null 表示正常结束）
export function streamChat(baseUrl: string, token: string, agentId: string, sessionId: string,
  parts: ChatInputPart[], onDelta: (delta: StreamDelta) => void,
  onDone: (error: string | null) => void): ChatStreamHandle {
  const req: http.HttpRequest = http.createHttp();
  const parser: SseParser = new SseParser();
  const classifier: StreamEventClassifier = new StreamEventClassifier();
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  let settled: boolean = false;

  const finish = (error: string | null): void => {
    if (settled) {
      return;
    }
    settled = true;
    onDone(error);
    req.destroy();
  };

  const emit = (event: SseEvent): void => {
    if (settled) {
      return;
    }
    const err: string | null = streamError(event);
    if (err !== null) {
      finish(err);
      return;
    }
    const delta: StreamDelta | null = classifier.consume(event);
    if (delta !== null) {
      onDelta(delta);
    }
  };

  const header: Record<string, Object> = {
    'Content-Type': 'application/json',
    'Accept': 'text/event-stream'
  };
  if (token.length > 0) {
    header['Authorization'] = `Bearer ${token}`;
  }
  if (agentId.length > 0) {
    header['X-Agent-Id'] = agentId;
  }
  const message: ChatInputMessage = { role: 'user', content: parts };
  const payload: ChatStreamRequest = {
    input: [message],
    session_id: sessionId,
    user_id: 'mobile',
    channel: 'console',
    stream: true
  };
  const options: http.HttpRequestOptions = {
    method: http.RequestMethod.POST,
    header: header,
    extraData: JSON.stringify(payload),
    connectTimeout: 10000,
    readTimeout: 0,          // 0 = 不超时（流式响应持续期间不中断）
    expectDataType: http.HttpDataType.STRING
  };

  req.on('dataReceive', (chunk: ArrayBuffer): void => {
    const decodeOpts: DecodeStreamOptions = { stream: true };
    const chunkText: string = decoder.decodeWithStream(new Uint8Array(chunk), decodeOpts);
    const events: SseEvent[] = parser.push(chunkText);
    for (const ev of events) {
      emit(ev);
    }
  });
  req.on('dataEnd', (): void => {
    const rest: SseEvent[] = parser.finish();
    for (const ev of rest) {
      emit(ev);
    }
    finish(null);
  });
  req.requestInStream(`${baseUrl}/api/console/chat`, options, (err: Error): void => {
    if (err !== undefined && err !== null) {
      finish(err.message);
    }
  });

  return new ChatStream((): void => {
    finish(null);
  });
}

export async function stopChat(baseUrl: string, token: string, agentId: string,
  chatId: string): Promise<void> {
  const resp: http.HttpResponse = await doRequest(
    `${baseUrl}/api/console/chat/stop?chat_id=${encodeURIComponent(chatId)}`,
    http.RequestMethod.POST, null, token.length > 0 ? token : null, agentId);
  if (resp.responseCode < 200 || resp.responseCode >= 300) {
    throw new ConnectError(`停止失败（HTTP ${resp.responseCode}）。`);
  }
}

// 上传结果（对齐 PR #7378 client.ts upload → UploadResult）
export interface UploadResult {
  url: string;
  fileName: string;
  size: number;
}

// 上传单个附件：POST {base}/api/console/upload，multipart/form-data，表单字段名固定为 file
// （对齐 RN form.append("file", …)；服务端按 file 取件）。
// 用 http.request 的 multiFormDataList 走与其它请求同一套鉴权头，且能直接拿到 JSON 响应体。
export async function uploadAttachment(baseUrl: string, token: string, agentId: string,
  filePath: string, fileName: string, mime: string): Promise<UploadResult> {
  const form: http.MultiFormData = {
    name: 'file',
    contentType: mime,
    remoteFileName: fileName,
    filePath: filePath
  };
  const header: Record<string, Object> = {
    'Content-Type': 'multipart/form-data',
    'Accept': 'application/json'
  };
  if (token.length > 0) {
    header['Authorization'] = `Bearer ${token}`;
  }
  if (agentId.length > 0) {
    header['X-Agent-Id'] = agentId;
  }
  const options: http.HttpRequestOptions = {
    method: http.RequestMethod.POST,
    header: header,
    multiFormDataList: [form],
    connectTimeout: 15000,
    readTimeout: 60000,
    expectDataType: http.HttpDataType.STRING
  };
  const req: http.HttpRequest = http.createHttp();
  try {
    const resp: http.HttpResponse = await req.request(`${baseUrl}/api/console/upload`, options);
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      throw new ConnectError(`附件上传失败（HTTP ${resp.responseCode}）。`);
    }
    const data: Record<string, Object> = JSON.parse(resp.result as string) as Record<string, Object>;
    const url: string = strOf(data, 'url');
    const name: string = strOf(data, 'file_name');
    const size: Object = data['size'];
    if (url.length === 0) {
      throw new ConnectError('附件上传失败：服务端未返回文件地址。');
    }
    const out: UploadResult = {
      url: url,
      fileName: name.length > 0 ? name : fileName,
      size: typeof size === 'number' ? size as number : 0
    };
    return out;
  } finally {
    req.destroy();
  }
}
