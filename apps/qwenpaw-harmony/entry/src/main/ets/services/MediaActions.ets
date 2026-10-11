/*
 * 聊天媒体「保存到相册 / 系统分享」—— 对齐 PR #7378 features/chat/mediaActions.ts。
 *
 * 取址与命名同 7378：URL 走 mediaUrl（本工程在 ChatDetailPage 内，http/https/data 原样、相对路径拼
 * {base}/api/files/preview）；文件名取 part.name 或 URL 末段，非法字符替换、截断 100。
 * 落盘：下载到应用缓存目录（filesDir/cache）后再消费。
 *
 * 权限口径：本工程只声明 ohos.permission.INTERNET，故「保存到相册」不用 MediaLibrary 权限申请，
 * 而走官方安全控件 SaveButton ——「点击即临时获得存储权限（1 分钟内单次访问媒体库特权接口）」，
 * 与 7378 的 requestPermissionsAsync 路线等价但无需声明权限。
 * 分享走 ShareKit 分享面板（系统分享，无需权限）。
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { http } from '@kit.NetworkKit';
import { QpConnection, loadConnection } from './ConnectionStore';

// 与 7378 defaultName 同口径
export function defaultNameOf(type: string): string {
  if (type === 'image') {
    return 'qwenpaw-image.png';
  }
  if (type === 'video') {
    return 'qwenpaw-video.mp4';
  }
  if (type === 'audio') {
    return 'qwenpaw-audio.m4a';
  }
  return 'qwenpaw-file';
}

// 与 7378 safeName 同口径：仅保留字母数字/下划线/点/中横/汉字，取末 100 字符
export function safeNameOf(value: string, type: string): string {
  const cleaned: string = value.replace(/[^\w.\-一-鿿]/g, '-').slice(-100);
  return cleaned.length > 0 ? cleaned : defaultNameOf(type);
}

function cacheDirOf(ctx: common.Context): string {
  return `${ctx.cacheDir}/${Date.now()}-`;
}

// 取媒体接口所需的鉴权头：相对路径的媒体走本机 QwenPaw 的 /api/files/preview，与其他请求同源，
// 必须带同一套 Bearer/X-Agent-Id（否则 401，保存与分享静默失败）；绝对 URL（第三方/内联 data）
// 一律不带凭据，避免把令牌发给外部主机。
async function authHeadersOf(ctx: common.Context, url: string): Promise<Record<string, Object>> {
  const header: Record<string, Object> = {};
  const conn: QpConnection | null = await loadConnection(ctx);
  if (conn !== null && url.startsWith(conn.baseUrl)) {
    if (conn.token.length > 0) {
      header['Authorization'] = `Bearer ${conn.token}`;
    }
    if (conn.agentId.length > 0) {
      header['X-Agent-Id'] = conn.agentId;
    }
  }
  return header;
}

/** 下载媒体到应用缓存目录，返回文件路径；失败抛错（调用方给 toast）。 */
export async function downloadToCache(ctx: common.Context, url: string, type: string, name: string): Promise<string> {
  const req: http.HttpRequest = http.createHttp();
  try {
    const resp: http.HttpResponse = await req.request(url, {
      method: http.RequestMethod.GET,
      header: await authHeadersOf(ctx, url),
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 60000
    });
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      throw new Error(`HTTP ${resp.responseCode}`);
    }
    const buf: ArrayBuffer = resp.result as ArrayBuffer;
    const path: string = cacheDirOf(ctx) + safeNameOf(name, type);
    const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
    fileIo.writeSync(f.fd, buf);
    fileIo.closeSync(f);
    return path;
  } finally {
    req.destroy();
  }
}

/** 安全控件 SaveButton 回调内调用：已拿到临时授权，创建媒体库资源并写入文件内容。 */
export async function saveToGallery(ctx: common.Context, type: string, path: string): Promise<void> {
  const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
  let photoType: photoAccessHelper.PhotoType = photoAccessHelper.PhotoType.IMAGE;
  let ext: string = 'png';
  if (type === 'video') {
    photoType = photoAccessHelper.PhotoType.VIDEO;
    ext = 'mp4';
  } else if (type !== 'image') {
    photoType = photoAccessHelper.PhotoType.IMAGE;
    ext = 'bin';
  }
  const uri: string = await helper.createAsset(photoType, ext);
  const src = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  const dst = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
  try {
    const stat = fileIo.statSync(src.fd);
    const buf = new ArrayBuffer(stat.size);
    fileIo.readSync(src.fd, buf);
    fileIo.writeSync(dst.fd, buf);
  } finally {
    fileIo.closeSync(src);
    fileIo.closeSync(dst);
  }
}

/** 系统分享面板（ShareKit）；anchorId 为分享面板贴靠的控件 id。 */
export function shareFile(ctx: common.UIAbilityContext, path: string, type: string, anchorId: string): void {
  let dataType: string = utd.UniformDataType.FILE;
  if (type === 'image') {
    dataType = utd.UniformDataType.IMAGE;
  } else if (type === 'video') {
    dataType = utd.UniformDataType.VIDEO;
  } else if (type === 'audio') {
    dataType = utd.UniformDataType.AUDIO;
  }
  const data: systemShare.SharedData = new systemShare.SharedData({
    utd: dataType,
    uri: `file://${path}`
  });
  const controller: systemShare.ShareController = new systemShare.ShareController(data);
  controller.show(ctx, { anchor: anchorId });
}
