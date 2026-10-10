/*
 * 连接持久化 —— @ohos.data.preferences（对齐 PR #7378 storage/connection.ts 的
 * 单连接 v1 形态；PR 用 SecureStore/Keychain，鸿蒙一期用应用沙箱 preferences，
 * 已知差距：token 未进 HUKS 安全存储，LAN 调试场景可接受，商用前需补）。
 */

import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';

export interface QpConnection {
  baseUrl: string;
  token: string;
  username: string;
  agentId: string;
  source: string;
  serverMode: string;
}

const STORE_NAME: string = 'qwenpaw.connection';
const KEY: string = 'qwenpaw.mobile.connection.v1';

export async function loadConnection(context: Context): Promise<QpConnection | null> {
  try {
    const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
    const raw: preferences.ValueType = await store.get(KEY, '');
    if (typeof raw !== 'string' || raw.length === 0) {
      return null;
    }
    const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    if (typeof parsed['baseUrl'] !== 'string' || typeof parsed['token'] !== 'string') {
      return null;
    }
    const conn: QpConnection = {
      baseUrl: parsed['baseUrl'] as string,
      token: parsed['token'] as string,
      username: typeof parsed['username'] === 'string' ? parsed['username'] as string : '',
      agentId: typeof parsed['agentId'] === 'string' ? parsed['agentId'] as string : 'default',
      source: 'private',
      serverMode: typeof parsed['serverMode'] === 'string' ? parsed['serverMode'] as string : ''
    };
    return conn;
  } catch (e) {
    return null;
  }
}

export async function saveConnection(context: Context, conn: QpConnection): Promise<void> {
  const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
  await store.put(KEY, JSON.stringify(conn));
  await store.flush();
}

export async function clearConnection(context: Context): Promise<void> {
  const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
  await store.delete(KEY);
  await store.flush();
}
