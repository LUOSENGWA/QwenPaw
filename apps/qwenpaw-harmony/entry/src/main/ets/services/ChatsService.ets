/*
 * 会话列表服务 —— GET {base}/api/chats?archived=${archived}（对齐 PR #7378 client.ts listChats）。
 * ChatSpec 字段防御式解析；updated_at ISO 字符串转本地展示（相对时间）。
 */

import { http } from '@kit.NetworkKit';
import { doRequest, jsonOf, ConnectError } from './ConnectionService';

export interface ChatInfo {
  id: string;
  sessionId: string;     // 会话的 session_id（发送用；对齐 RN store 的 sessionId: chat.session_id）
  name: string;
  updatedAtMs: number;   // 0 = 未知
  pinned: boolean;
}

function strOf(rec: Record<string, Object>, key: string): string {
  const v: Object = rec[key];
  return typeof v === 'string' ? v as string : '';
}

export function isoToMs(iso: string): number {
  if (iso.length === 0) {
    return 0;
  }
  const t: number = Date.parse(iso);
  return isNaN(t) ? 0 : t;
}

// 相对时间：今天 HH:mm / 今年 M月d日 / 跨年 yyyy/M/d
export function relativeTime(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const d: Date = new Date(ms);
  const now: Date = new Date();
  const sameYear: boolean = d.getFullYear() === now.getFullYear();
  const sameDay: boolean = sameYear && d.getMonth() === now.getMonth()
    && d.getDate() === now.getDate();
  if (sameDay) {
    return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
  }
  if (sameYear) {
    return `${d.getMonth() + 1}月${d.getDate()}日`;
  }
  return `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`;
}

export async function fetchChats(baseUrl: string, token: string, agentId: string,
  archived: boolean = false): Promise<ChatInfo[]> {
  const resp: http.HttpResponse = await doRequest(
    `${baseUrl}/api/chats?archived=false`, http.RequestMethod.GET, null,
    token.length > 0 ? token : null, agentId);
  if (resp.responseCode === 401 || resp.responseCode === 403) {
    throw new ConnectError(`票据已失效（HTTP ${resp.responseCode}），请重新连接。`);
  }
  if (resp.responseCode !== 200) {
    throw new ConnectError(`读取会话列表失败（HTTP ${resp.responseCode}）。`);
  }
  const data: Object = jsonOf(resp)['chats'] !== undefined ? jsonOf(resp)['chats'] : jsonOf(resp);
  if (!Array.isArray(data)) {
    // /chats 直接返回数组（PR listChats 类型 = ChatSpec[]）
    return [];
  }
  const items: Object[] = data as Object[];
  const out: ChatInfo[] = [];
  for (const item of items) {
    const c: Record<string, Object> = item as Record<string, Object>;
    const id: string = strOf(c, 'id');
    const name: string = strOf(c, 'name').length > 0 ? strOf(c, 'name') : id;
    const pinned: Object = c['pinned'];
    const info: ChatInfo = {
      id: id,
      name: name,
      sessionId: strOf(c, 'session_id').length > 0 ? strOf(c, 'session_id') : strOf(c, 'id'),
      updatedAtMs: isoToMs(strOf(c, 'updated_at')),
      pinned: typeof pinned === 'boolean' ? pinned as boolean : false
    };
    out.push(info);
  }
  // 对齐 RN sortChatsByAttention 的 recency 排序：新 → 旧（一期无活跃度优先级；
  // 时间戳未知(0)的会话稳定沉底）
  // 置顶会话排最前（对齐 RN chats.tsx 的 pinned 分组），其余按新→旧
  out.sort((a: ChatInfo, b: ChatInfo): number => {
    if (a.pinned !== b.pinned) {
      return a.pinned ? -1 : 1;
    }
    return b.updatedAtMs - a.updatedAtMs;
  });
  return out;
}
