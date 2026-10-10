/*
 * 配对码解析 —— 移植 PR #7378 src/api/pairing.ts 的 direct 分支（一期仅 LAN 直连）。
 * 配对码格式：qwenpaw://pair?v=1&base_url=<http(s) 地址>&ticket=<≥32 字符>
 * 远程中转配对（v2 JSON）一期不支持。
 */

export interface DirectPairing {
  baseUrl: string;
  ticket: string;
}

export function normalizeBaseUrl(value: string): string {
  const trimmed: string = value.trim();
  if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
    throw new Error('QwenPaw 地址必须使用 HTTP 或 HTTPS。');
  }
  const noFrag: string = trimmed.split('#')[0];
  if (noFrag.indexOf('?') >= 0) {
    throw new Error('QwenPaw 地址不能带查询参数。');
  }
  const authority: string = noFrag.slice(noFrag.indexOf('://') + 3);
  if (authority.indexOf('@') >= 0) {
    throw new Error('QwenPaw 地址不能带账号凭据。');
  }
  return noFrag.replace(/\/+$/, '');
}

export function hostOf(baseUrl: string): string {
  const schemeIdx: number = baseUrl.indexOf('://');
  if (schemeIdx < 0) {
    return '';
  }
  const rest: string = baseUrl.slice(schemeIdx + 3);
  const end: number = rest.search(/[\/:?#]/);
  const host: string = end < 0 ? rest : rest.slice(0, end);
  return host.toLowerCase();
}

export function parsePairingUri(value: string): DirectPairing {
  const v: string = value.trim();
  if (v.startsWith('{')) {
    throw new Error('远程中转配对一期暂不支持（仅 LAN 直连）。');
  }
  if (!v.startsWith('qwenpaw://pair')) {
    throw new Error('这不是一个 QwenPaw 配对码。');
  }
  const params: Record<string, string> = {};
  const qIndex: number = v.indexOf('?');
  if (qIndex >= 0) {
    const pairs: string[] = v.slice(qIndex + 1).split('&');
    for (const p of pairs) {
      const eq: number = p.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      params[decodeURIComponent(p.slice(0, eq))] = decodeURIComponent(p.slice(eq + 1));
    }
  }
  const version: number = Number(params['v'] !== undefined ? params['v'] : '0');
  const baseUrl: string = params['base_url'] !== undefined ? params['base_url'] : '';
  const ticket: string = params['ticket'] !== undefined ? params['ticket'] : '';
  if (version !== 1 || ticket.length < 32) {
    throw new Error('这个 QwenPaw 配对码无效或已过期。');
  }
  const pairing: DirectPairing = { baseUrl: normalizeBaseUrl(baseUrl), ticket: ticket };
  return pairing;
}

export function parseManualInput(baseUrlRaw: string, ticketRaw: string): DirectPairing {
  const baseUrl: string = normalizeBaseUrl(baseUrlRaw);
  const ticket: string = ticketRaw.trim();
  if (ticket.length > 0 && ticket.length < 32) {
    throw new Error('配对码太短（至少 32 字符）。若服务未开账号体系，可留空直连。');
  }
  const pairing: DirectPairing = { baseUrl: baseUrl, ticket: ticket };
  return pairing;
}
