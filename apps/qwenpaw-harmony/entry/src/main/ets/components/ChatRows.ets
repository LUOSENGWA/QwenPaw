/*
 * 聊天行组件 —— 会话详情页把「一个回合 = 一个 ListItem」拆成「一行 = 一个 ListItem」后的行渲染层。
 *
 * 行类型（ConversationRow.kind）：
 *   user    —— 用户气泡（右对齐实底）
 *   message —— 一段响应文本气泡（markdown / 选择态纯文本）
 *   steps   —— 一个步骤组卡（ProcessCard：思考 / 工具）
 *   media   —— 该回合的工具产出媒体（图片 / 文件卡）
 *   pending —— 待发回合的「正在生成…」占位
 *
 * 拆分动机：整回合一个 ListItem 时，流式期间每个 flush 都会让 List 重排这个巨大 item，
 * 过程卡（数百行）参与重排直接卡死；拆成行后 List 的虚拟化对每行生效，只有"正在长的那一行"重排。
 * 行组件全部自持交互态（展开 / 选择 / 复制），使某行重排/重建不牵连其它行。
 */

import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { UIContext, SymbolGlyphModifier } from '@kit.ArkUI';
import {
  DisplayMessage, DisplayPart, textOfParts
} from '../services/ChatDetailService';
import { ThemeSnapshot, ThemeManager } from '../theme/ThemeManager';
import { UiTokens } from '../theme/UiTokens';
import { downloadToCache, saveToGallery, shareFile, safeNameOf, openCachedFilePreview,
  canSystemPreview, isMarkdownName, isTextualName, readTextFile, TextRead,
  saveCachedFileWithPicker, openCachedFileWithOtherApp, saveBytesToCache,
  defaultNameOf } from '../services/MediaActions';
import { healStreamingMarkdown } from '../services/StreamMarkdown';
import { fileIconOf } from '../theme/FileIcons';
import { isDarkMode } from '../theme/Accent';
import { SheetGate, moduleSheetOptions } from './SheetGate';
import { Markdown } from '../vendor/markdown/Index';
import { MarkdownOptions, MarkdownTheme, MarkdownFontStyle } from '../vendor/markdown/Index';
import { CodeStyle, CodeSpan, BlockQuoteStyle, DriveStyle } from '../vendor/markdown/src/main/ets/config/MarkdownTheme';
import { contextMenuOptions } from '../theme/MenuMaterial';

// ============ 扁平行模型 ============
// 会话被展平成行序列：List 的每个 ListItem 承载一行，键只含结构信息（回合 + 块序号），
// 行内容的变化走可观察对象原地更新（见下方 ConversationRow 注释）。
/*
 * 列表行模型：@Observed 类 + 行组件用 @ObjectLink 接收 —— 这是"流式期间只有那一行内容在变"
 * 的正确更新路径。ArkUI 的 ForEach 只在键变化时重跑 itemGenerator：把内容指纹放进键可以让在途行
 * 刷新，但代价是**每帧销毁重建该行**（整卡闪、滚动被打断，真机表现为"刷屏"）；改用可观察对象后，
 * 键保持结构键不变，页面只把新数据**赋值到同一个行对象**上，行组件原地更新（不重建子树）。
 * 在途回合的行由页面复用同一实例；已完结回合的行每次新建（没有观察者 → 不会产生无谓刷新）。
 */
@Observed
export class ConversationRow {
  key: string = '';            // ForEach 键（唯一且稳定，只含结构信息）
  kind: string = '';           // user | message | steps | media | pending
  turnId: string = '';         // 所属回合 id
  messages: DisplayMessage[] = [];  // message / steps 行的消息；user 行为 [用户消息]
  parts: DisplayPart[] = [];   // media 行的媒体分片
  pending: boolean = false;    // 所属回合是否在途
  expanded: boolean = false;   // 过程组（stepsHeader）当前是否展开（展开态由页面持有）
  groupKey: string = '';       // 过程组的稳定键（turnId:块序号），用于页面切换展开态
  last: boolean = false;       // message 行是否为该回合最终回复（显示「最终回复」标签）
  generating: boolean = false; // steps 行是否为该回合正在生成的「活动组」
}

export function rowOf(kind: string, key: string, turnId: string, messages: DisplayMessage[],
  parts: DisplayPart[]): ConversationRow {
  const r: ConversationRow = new ConversationRow();
  r.kind = kind;
  r.key = key;
  r.turnId = turnId;
  r.messages = messages;
  r.parts = parts;
  return r;
}

// 展开态「不限行数」用的行数上限：不能用 maxLines(0) —— 真机实测该值被当作 0 行处理，
// 展开后文本反而整段不显示（Text 节点消失）。用一个足够大的整数表达「不限制」。
const NO_LINE_LIMIT: number = 100000;

// 喂给 Markdown 的内容节流窗口（ms）。对应 QwenCode web-shell Markdown.tsx 的 useThrottledValue
// （React useDeferredValue 的替代实现；它取 80ms，本工程一次 flush 已是 60ms 的批量，取稍宽的窗口
// 让"整段重新解析"的节奏更稳）：本工程 Markdown 组件每次 content 变化都会重起一次解析任务，
// 流式期间逐分片重解析会让整块反复重排。仅对喂入内容做节流，窗口内的最后一批变化由定时器兜住，
// 流一停立即落盘（不会停在旧内容上）；行内文本与非 markdown 部分不受影响。
const MD_THROTTLE_MS: number = 180;
// 页内只读预览的文本读取上限：超过就只读前 256KB 并附截断提示（避免超大文件卡住渲染）
const TEXT_PREVIEW_CAP: number = 256 * 1024;

// ============ 媒体渲染（对齐 PR #7378 features/chat/MessageParts.tsx）============
// 媒体 URL 解析对齐 7378 client.ts mediaSource：http/https/data 原样，
// 其余（相对路径 / file://）拼 {baseUrl}/api/files/preview{path}。
// 注：ArkTS Image 组件不支持自定义请求头（7378 的 mediaSource 会带 Authorization / X-Agent-Id），
// 开放模式免票据可直接访问；需票据的部署下带认证媒体暂不显示（后续以 ArrayBuffer 下载 → PixelMap 补齐）。
function mediaUrl(baseUrl: string, rawUrl: string): string {
  if (rawUrl.startsWith('http://') || rawUrl.startsWith('https://') || rawUrl.startsWith('data:')) {
    return rawUrl;
  }
  const path: string = rawUrl.startsWith('file://') ? rawUrl.slice(7) : rawUrl;
  // 绝对路径（工具写工作区外的文件、截图等）→ 文件预览通道；
  // 相对路径（工具在工作区内写文件时给的就是相对路径）→ 工作区文件下载通道
  if (path.startsWith('/')) {
    return `${baseUrl}/api/files/preview${path}`;
  }
  return `${baseUrl}/api/workspace/file-download?root=workspace&path=${encodeURIComponent(path)}`;
}

function mediaPartsOf(parts: DisplayPart[]): DisplayPart[] {
  return parts.filter((p: DisplayPart): boolean => p.type !== 'text');
}

// 同一相对路径的另一个工作区根：产物可能落在「绑定项目目录」（console 的 project 根）或
// 「智能体自身存储根」（workspace 根）两处 —— console 对相对路径固定取 project 根，本工程
// 历史上按 workspace 根取，两者各自覆盖一部分产物。故下载失败时换另一个根再取一次。
// 绝对路径 / 内联数据没有第二个根（走 /api/files/preview 通道），返回空串表示无可回退。
function altRootUrl(baseUrl: string, rawUrl: string): string {
  if (rawUrl.startsWith('http://') || rawUrl.startsWith('https://') || rawUrl.startsWith('data:')) {
    return '';
  }
  const path: string = rawUrl.startsWith('file://') ? rawUrl.slice(7) : rawUrl;
  if (path.startsWith('/')) {
    return '';
  }
  return `${baseUrl}/api/workspace/file-download?root=project&path=${encodeURIComponent(path)}`;
}

// 该消息是否有可见内容（非空白文本 / 媒体分片 / 错误）。服务端会下发 text 只有 "\n\n" 的 message
// 记录（实测同一会话 26 条），它渲染成空内容 + 卡片底色 = 一张空白卡，故按可见性判定后不出行。
export function rowHasVisibleContent(m: DisplayMessage): boolean {
  if (m.error !== undefined && m.error.length > 0) {
    return true;
  }
  for (const p of m.parts) {
    if (p.type !== 'text') {
      return true;
    }
    if (p.text !== undefined && p.text.trim().length > 0) {
      return true;
    }
  }
  return false;
}

// 复制纯文本到系统剪贴板；成功返回 true（调用方据此置「复制完成」反馈）
async function copyTextToClipboard(ctx: UIContext, text: string): Promise<boolean> {
  if (text.length === 0) {
    return false;
  }
  try {
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    await pasteboard.getSystemPasteboard().setData(data);
    return true;
  } catch (e) {
    return false;
  }
}

// 单个媒体块：图片 → Image（data URL 先转 PixelMap）；video/audio/file → 文件卡
@Component
struct MediaThumb {
  @Prop part: DisplayPart = { type: '' };
  @Prop baseUrl: string = '';
  @Prop anchorId: string = '';                 // 分享面板贴靠锚点 id（长按菜单里分享时用）
  @State pixelMap: image.PixelMap | undefined = undefined;
  @State failed: boolean = false;
  @State busy: boolean = false;
  // 内联 base64 图（data: URL）的原始字节：除解码成 PixelMap 展示外另留一份，
  // 点开时落成缓存文件交给系统预览（这类图没有可下载的远端地址）
  private inlineBytes: Uint8Array | undefined = undefined;
  // 页内只读预览（Preview Kit 打不开的文本/代码类文件）：内容 + 是否 markdown + 标题（文件名）
  @State textShown: boolean = false;
  @State textBody: string = '';
  @State textMd: boolean = false;
  @State textName: string = '';
  @State dark: boolean = false;
  private sheetGate: SheetGate = new SheetGate();

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  // 打开失败提示：区分「服务端已经没有这个文件」与「格式不支持」。
  // 产物源文件消失是常态（工具写到容器 /tmp 的临时图，服务端清理后只剩历史里的路径），
  // 这时给「源文件已不在服务端」，不要一律报"无法预览"让人以为格式不支持。
  private failToast(e: Object): void {
    const msg: string = (e as Error).message !== undefined ? (e as Error).message : '';
    if (msg.indexOf('404') >= 0) {
      this.toast(this.t($r('app.string.chat_file_gone')));
      return;
    }
    this.toast(this.t($r('app.string.chat_file_no_preview')));
  }

  // 资源文案取字符串（工程统一口径：resourceManager.getStringSync）
  private t(res: Resource): string {
    try {
      const host: common.Context = this.getUIContext().getHostContext() as common.Context;
      return host.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  private hostCtx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private urlOf(): string {
    return mediaUrl(this.baseUrl, this.part.url !== undefined ? this.part.url : '');
  }

  // 落到缓存（带回退），返回缓存路径 —— 点开预览 / 保存到 / 分享 / 其他应用打开都先过这里：
  //   · 内联 base64（data:）没有可下载的远端地址 → 用内存里那份字节直接落盘；
  //   · 远端地址失败且是相对路径 → 换另一个工作区根再取一次（见 altRootUrl）。
  private async fetchToCache(type: string): Promise<string> {
    const ctx: common.UIAbilityContext = this.hostCtx();
    const raw: string = this.part.url !== undefined ? this.part.url : '';
    if (raw.startsWith('data:')) {
      const bytes: Uint8Array | undefined = this.inlineBytes;
      if (bytes === undefined) {
        throw new Error('inline data not decoded yet');
      }
      return saveBytesToCache(ctx, bytes, this.fileNameOf());
    }
    try {
      return await downloadToCache(ctx, this.urlOf(), type, this.fileNameOf());
    } catch (e) {
      const alt: string = altRootUrl(this.baseUrl, raw);
      if (alt.length === 0) {
        throw e as Error;
      }
      return await downloadToCache(ctx, alt, type, this.fileNameOf());
    }
  }

  private fileNameOf(): string {
    const rawUrl: string = this.part.url !== undefined ? this.part.url : '';
    const given: string = this.part.name !== undefined && this.part.name.length > 0 ? this.part.name : '';
    if (given.length > 0) {
      return safeNameOf(given, this.part.type);
    }
    // 内联数据没有文件名（末段是 base64 正文，切出来是垃圾）→ 按类型给默认名
    if (rawUrl.startsWith('data:')) {
      return defaultNameOf(this.part.type);
    }
    const segs: string[] = this.urlOf().split('/');
    const last: string = segs.length > 0 ? segs[segs.length - 1] : '';
    return safeNameOf(last, this.part.type);
  }

  // 文件卡副标题：工具产出文件显示变化类型（新建 / 修改 / 发送，对齐 console 的 artifactChange），
  // 其余分片就显示类型名
  private subtitle(): string {
    const note: string = this.part.note !== undefined ? this.part.note : '';
    if (note === 'created') {
      return this.t($r('app.string.chat_file_created'));
    }
    if (note === 'modified') {
      return this.t($r('app.string.chat_file_modified'));
    }
    if (note === 'sent') {
      return this.t($r('app.string.chat_file_sent'));
    }
    return this.part.type;
  }

  // 保存到相册：安全控件回调内已有临时授权 → 下载到缓存再写入媒体库（对齐 7378 cacheMedia + saveToLibrary）
  handleSave: SaveButtonCallback = async (event: ClickEvent, result: SaveButtonOnClickResult): Promise<void> => {
    if (result !== SaveButtonOnClickResult.SUCCESS || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ctx: common.UIAbilityContext = this.hostCtx();
      const path: string = await downloadToCache(ctx, this.urlOf(), this.part.type, this.fileNameOf());
      await saveToGallery(ctx, this.part.type, path);
      this.toast(this.t($r('app.string.chat_media_saved')));
    } catch (e) {
      this.toast(`${this.t($r('app.string.chat_media_save_failed'))}: ${(e as Error).message}`);
    } finally {
      this.busy = false;
    }
  };

  // 分享：下载到缓存后走系统分享面板（ShareKit）
  private async shareMedia(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ctx: common.UIAbilityContext = this.hostCtx();
      const path: string = await downloadToCache(ctx, this.urlOf(), this.part.type, this.fileNameOf());
      shareFile(ctx, path, this.part.type, this.anchorId);
    } catch (e) {
      this.toast(`${this.t($r('app.string.chat_media_share_failed'))}: ${(e as Error).message}`);
    } finally {
      this.busy = false;
    }
  }

  // 点文件卡 → 打开：Preview Kit 支持表内的格式（Office / pdf / 图片 / 音视频 / 文本类）交给系统预览；
  // 表外的文本/代码类（md / py / sh / json / log …）系统预览打不开，落页内只读预览（md 走渲染）。
  private openFile(): void {
    const name: string = this.fileNameOf();
    if (!canSystemPreview(name) && isTextualName(name)) {
      this.openTextPreview(name);
      return;
    }
    this.previewFile();
  }

  // 页内只读预览：下载到缓存 → 按文本读取（超过 TEXT_PREVIEW_CAP 截断并附提示）→ 半模态面板
  private async openTextPreview(name: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const path: string = await this.fetchToCache(this.part.type);
      const read: TextRead = readTextFile(path, TEXT_PREVIEW_CAP);
      if (read.text.length === 0) {
        throw new Error('empty');
      }
      if (!this.sheetGate.request()) {
        return;
      }
      this.dark = isDarkMode(this.hostCtx());
      this.textName = name;
      this.textMd = isMarkdownName(name);
      this.textBody = read.truncated
        ? `${read.text}\n\n[${this.t($r('app.string.module_files_truncated'))}]`
        : read.text;
      this.textShown = true;
    } catch (e) {
      this.failToast(e as Object);
    } finally {
      this.busy = false;
    }
  }

  // 页内只读预览面板：标题 = 文件名，正文 = markdown 渲染 / 纯文本（跟随半模态材质与关叉避让口径）
  @Builder
  textPreviewSheet() {
    Column() {
      Text(this.textName)
        .fontSize(UiTokens.fsTitle)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ bottom: 12 })
      if (this.textMd) {
        Scroll() {
          Column() {
            Markdown({ content: this.textBody, options: { darkMode: this.dark } })
          }
          .width('100%')
          .padding(UiTokens.cardPad)
          .borderRadius(UiTokens.cardRadius)
          .backgroundColor($r('app.color.sheet_card_bg'))
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)
      } else {
        Scroll() {
          Text(this.textBody)
            .fontSize(UiTokens.fsSecondary)
            .lineHeight(20)
            .width('100%')
            .padding(UiTokens.cardPad)
            .borderRadius(UiTokens.cardRadius)
            .backgroundColor($r('app.color.sheet_card_bg'))
            .textAlign(TextAlign.Start)
            .wordBreak(WordBreak.BREAK_ALL)
            .copyOption(CopyOptions.LocalDevice)
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: UiTokens.pageHMargin, right: UiTokens.pageHMargin, bottom: UiTokens.pageHMargin })
  }

  // 保存到…：下载到缓存后交给系统 picker 选位置（可选目录）——与「文件」模块同一出口
  private async saveViaPicker(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ctx: common.UIAbilityContext = this.hostCtx();
      const path: string = await this.fetchToCache(this.part.type);
      const saved: boolean = await saveCachedFileWithPicker(ctx, path, this.fileNameOf());
      if (saved) {
        this.toast(this.t($r('app.string.module_files_downloaded')));
      }
    } catch (e) {
      this.toast(`${this.t($r('app.string.chat_media_save_failed'))}: ${(e as Error).message}`);
    } finally {
      this.busy = false;
    }
  }

  // 其他应用打开：下载到缓存后走官方隐式 Want（见 services/MediaActions.openCachedFileWithOtherApp）
  private async openExternally(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ctx: common.UIAbilityContext = this.hostCtx();
      const path: string = await this.fetchToCache(this.part.type);
      await openCachedFileWithOtherApp(ctx, path, this.fileNameOf());
    } catch (e) {
      this.toast(this.t($r('app.string.module_files_open_external_failed')));
    } finally {
      this.busy = false;
    }
  }

  // 点开 → 系统预览服务（Preview Kit，文本/Office/图片/音视频都能开）。内联 base64 图与远端图
  // 走同一出口（差别只在 fetchToCache 怎么拿到文件）。
  // 预览不可用（格式不支持 / 设备无预览服务 / 源文件已被服务端清理）时给对应提示。
  private async previewFile(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const ctx: common.UIAbilityContext = this.hostCtx();
      const path: string = await this.fetchToCache(this.part.type);
      await openCachedFilePreview(ctx, path, this.fileNameOf());
    } catch (e) {
      this.failToast(e as Object);
    } finally {
      this.busy = false;
    }
  }

  // 长按菜单：保存 / 分享 / 其他应用打开 —— 与工作台「文件」模块同一套出口
  // （图片/视频的「保存」= 安全控件存相册，文件卡的「保存」= 系统 picker 选目录另存）
  @Builder
  mediaMenu() {
    Column() {
      if (this.part.type === 'image' || this.part.type === 'video') {
        SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.DOWNLOAD })
          .iconSize(20)
          .onClick(this.handleSave)
      } else {
        Row({ space: 8 }) {
          Image($r('app.media.folder_plus'))
            .width(18).height(18)
            .fillColor($r('app.color.text_secondary'))
          Text($r('app.string.module_files_save_as'))
            .fontSize(UiTokens.fsBody)
            .fontColor($r('app.color.text_primary_strong'))
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .onClick((): void => {
          this.saveViaPicker();
        })
      }
      Divider().color($r('app.color.card_bg')).strokeWidth(1)
      Row({ space: 8 }) {
        Image($r('app.media.link'))
          .width(18).height(18)
          .fillColor($r('app.color.text_secondary'))
        Text($r('app.string.chat_media_share'))
          .fontSize(UiTokens.fsBody)
          .fontColor($r('app.color.text_primary_strong'))
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .onClick((): void => {
        this.shareMedia();
      })
      Divider().color($r('app.color.card_bg')).strokeWidth(1)
      Row({ space: 8 }) {
        Image($r('app.media.book_open'))
          .width(18).height(18)
          .fillColor($r('app.color.text_secondary'))
        Text($r('app.string.module_files_open_external'))
          .fontSize(UiTokens.fsBody)
          .fontColor($r('app.color.text_primary_strong'))
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .onClick((): void => {
        this.openExternally();
      })
    }
    .width(180)
    .padding(6)
  }

  aboutToAppear(): void {
    const url: string = this.part.url !== undefined ? this.part.url : '';
    if (this.part.type === 'image' && url.startsWith('data:')) {
      this.decodeDataUrl(url);
    }
  }

  // base64 data URL → PixelMap（ArkTS Image 不直读 data URL；对齐 7378 base64 source 分支）。
  // 原始字节另留一份：Image 只能"看"，点开要出文件（见 openInline）。
  private async decodeDataUrl(url: string): Promise<void> {
    const comma: number = url.indexOf(',');
    if (comma < 0) {
      return;
    }
    try {
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(url.slice(comma + 1));
      this.inlineBytes = bytes;
      const buf: ArrayBuffer =
        bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      const src: image.ImageSource = image.createImageSource(buf);
      this.pixelMap = await src.createPixelMap();
    } catch (e) {
      this.failed = true;
    }
  }

  @Builder
  FileCard() {
    Row() {
      Image(fileIconOf(this.fileNameOf()))
        .width(20)
        .height(20)
        .fillColor($r('app.color.text_secondary'))
        .margin({ right: 10 })
      Column() {
        Text(this.part.name !== undefined && this.part.name.length > 0 ? this.part.name : this.part.type)
          .fontSize(UiTokens.fsSecondary)
          .fontColor($r('app.color.text_primary_strong'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subtitle())
          .fontSize(UiTokens.fsCaption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor($r('app.color.card_bg'))
    .onClick((): void => {
      this.openFile();
    })
    // 页内只读预览面板（Preview Kit 表外的文本类才用得上），与长按菜单分挂不同节点：
    // 同一节点挂多个半模态只有最后一个生效（SheetGate 口径），故菜单留在外层容器
    .bindSheet(this.textShown, this.textPreviewSheet(),
      moduleSheetOptions(680, this.sheetGate, (v: boolean): void => {
        this.textShown = v;
      }))
  }

  build() {
    // 外包一层内置容器：既作为分享面板锚点（id），也承载长按菜单（自定义组件不能链式挂属性）
    Column() {
      if (this.part.type === 'image' && !this.failed) {
        if (this.pixelMap !== undefined) {
          Image(this.pixelMap)
            .width('100%')
            .aspectRatio(1.28)
            .objectFit(ImageFit.Cover)
            .borderRadius(UiTokens.cardRadius)
            .backgroundColor($r('app.color.card_bg'))
            // 内联 base64 图同样可点开：与远端图同一出口（点开 = 系统预览）
            .onClick((): void => {
              this.previewFile();
            })
        } else {
          Image(this.urlOf())
            .width('100%')
            .aspectRatio(1.28)
            .objectFit(ImageFit.Cover)
            .borderRadius(UiTokens.cardRadius)
            .backgroundColor($r('app.color.card_bg'))
            .onError((): void => {
              this.failed = true;
            })
            // 点图 → 系统预览（Preview Kit）：图片此前只能看不能开。
            // data: 内联图（pixelMap 分支）不挂点击——它没有可下载的远端地址
            .onClick((): void => {
              this.previewFile();
            })
        }
      } else {
        this.FileCard()
      }
    }
    .width('100%')
    .id(this.anchorId)
    // 长按菜单属弹窗类接口 → 走统一材质出口（此前漏传 options，菜单没有沉浸光感）
    .bindContextMenu(this.mediaMenu(), ResponseType.LongPress, contextMenuOptions())
  }
}

// 媒体块列表（跳过 text；文本已由气泡另行渲染）
@Component
struct MediaParts {
  @Prop parts: DisplayPart[] = [];
  @Prop baseUrl: string = '';

  build() {
    Column({ space: 6 }) {
      ForEach(mediaPartsOf(this.parts), (p: DisplayPart, i: number) => {
        MediaThumb({ part: p, baseUrl: this.baseUrl, anchorId: `chat_media_${i}` })
      }, (p: DisplayPart, i: number) => `${p.type}:${p.url !== undefined ? p.url : ''}:${i}`)
    }
    .width('100%')
  }
}

// ============ 选择态工具栏（气泡内：提示 + 复制全文 + 完成）============
// 对齐 7378 features/chat/MessageBubbleActions 的 selectionToolbar。用户气泡（实底）与
// 消息气泡（浅底）只差前景色，故用 inverted 区分，避免两处重复。
@Component
struct SelectionToolbar {
  @Prop inverted: boolean = false;
  @Prop copied: boolean = false;
  @Prop isDark: boolean = false;
  @Prop theme: ThemeSnapshot = ThemeManager.get().snapshot();
  onCopy: () => void = (): void => {};
  onDone: () => void = (): void => {};

  private fg(): ResourceColor {
    return this.inverted ? Color.White : (this.isDark ? this.theme.accentDark : this.theme.accent);
  }

  private hairline(): ResourceColor {
    return this.inverted ? '#3DFFFFFF' : $r('app.color.line');
  }

  build() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.smart_selection_area'))
        .fontSize(17)
        .fontColor([this.fg()])
      Text($r('app.string.chat_select_hint'))
        .fontSize(UiTokens.fsCaption)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.fg())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Button() {
        Image(this.copied ? $r('app.media.check') : $r('app.media.copy'))
          .width(18).height(18)
          .fillColor(this.fg())
      }
      .type(ButtonType.Normal)
      .backgroundColor(Color.Transparent)
      .stateEffect(false)
      .width(40)
      .height(40)
      .onClick((): void => {
        this.onCopy();
      })
      Button() {
        Image($r('app.media.x'))
          .width(19).height(19)
          .fillColor(this.inverted ? Color.White : $r('app.color.text_primary_strong'))
      }
      .type(ButtonType.Normal)
      .backgroundColor(Color.Transparent)
      .stateEffect(false)
      .width(40)
      .height(40)
      .onClick((): void => {
        this.onDone();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: 40 })
    .margin({ bottom: 2 })
    .border({ width: { bottom: 0.5 }, color: this.hairline() })
  }
}

// ============ 用户气泡行 ============
@Component
export struct UserRow {
  @Prop message: DisplayMessage = { id: '', role: 'user', kind: 'message', parts: [] };
  @Prop isDark: boolean = false;
  @Prop theme: ThemeSnapshot = ThemeManager.get().snapshot();
  @Prop baseUrl: string = '';
  @State selecting: boolean = false;
  @State copied: boolean = false;

  // 资源文案取字符串（工程统一口径：resourceManager.getStringSync）
  private t(res: Resource): string {
    try {
      const host: common.Context = this.getUIContext().getHostContext() as common.Context;
      return host.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  private text(): string {
    return textOfParts(this.message.parts);
  }

  private media(): DisplayPart[] {
    return mediaPartsOf(this.message.parts);
  }

  // 选择态禁掉长按菜单（改用右键触发），与 7378 一致
  private trigger(): ResponseType {
    return this.selecting || this.text().length === 0 ? ResponseType.RightClick : ResponseType.LongPress;
  }

  private async doCopy(): Promise<void> {
    const ok: boolean = await copyTextToClipboard(this.getUIContext(), this.text());
    const msg: string = ok ? this.t($r('app.string.chat_msg_copied')) : this.t($r('app.string.chat_msg_copy_failed'));
    this.getUIContext().getPromptAction().showToast({ message: msg });
    if (ok) {
      this.copied = true;
    }
  }

  @Builder
  bubbleMenu() {
    Menu() {
      MenuItem({
        content: this.t($r('app.string.chat_msg_copy')),
        symbolStartIcon: new SymbolGlyphModifier($r('app.media.copy'))
      })
        .onClick((): void => {
          this.doCopy();
        })
      MenuItem({
        content: this.t($r('app.string.chat_msg_select')),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.smart_selection_area'))
      })
        .onClick((): void => {
          if (this.text().length > 0) {
            this.copied = false;
            this.selecting = true;
          }
        })
    }
  }

  build() {
    Row() {
      Blank()
      Column() {
        if (this.selecting) {
          SelectionToolbar({
            inverted: true,
            copied: this.copied,
            isDark: this.isDark,
            theme: this.theme,
            onCopy: (): void => {
              this.doCopy();
            },
            onDone: (): void => {
              this.selecting = false;
            }
          })
        }
        if (this.text().length > 0) {
          Text(this.text())
            .fontSize(UiTokens.fsBody)
            .fontColor(Color.White)
            .lineHeight(21)
            .wordBreak(WordBreak.BREAK_WORD)
            .copyOption(this.selecting ? CopyOptions.LocalDevice : CopyOptions.None)
        }
        if (this.media().length > 0) {
          Column() {
            MediaParts({ parts: this.media(), baseUrl: this.baseUrl })
          }
          .width('100%')
          .margin({ top: this.text().length > 0 ? 6 : 0 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .constraintSize({ maxWidth: '78%' })
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .borderRadius(UiTokens.cardRadius)
      .backgroundColor(this.isDark ? this.theme.accentDark : this.theme.accent)
      .bindContextMenu(this.bubbleMenu(), this.trigger(), contextMenuOptions())
    }
    .width('100%')
    .margin({ top: 6, bottom: 6 })
    .justifyContent(FlexAlign.End)
  }
}

// ============ 消息气泡行（对齐 7378 MessageBubble）============
@Component
export struct MessageRow {
  @Prop @Watch('onMessageChanged') message: DisplayMessage = { id: '', role: 'assistant', kind: 'message', parts: [] };
  // 本条是否仍在流式写入（回合未落定）：渲染前对 markdown 做自愈（见 StreamMarkdown）
  @Prop @Watch('onMessageChanged') streaming: boolean = false;
  @Prop last: boolean = false;
  @Prop isDark: boolean = false;
  @Prop theme: ThemeSnapshot = ThemeManager.get().snapshot();
  @Prop baseUrl: string = '';
  @State expanded: boolean = false;
  @State selecting: boolean = false;
  @State copied: boolean = false;
  // 喂给 Markdown 的节流文本（见 MD_THROTTLE_MS 注释）
  @State mdShown: string = '';
  private mdTimer: number = -1;

  aboutToAppear(): void {
    this.mdShown = this.mdForRender();
  }

  aboutToDisappear(): void {
    if (this.mdTimer >= 0) {
      clearTimeout(this.mdTimer);
      this.mdTimer = -1;
    }
  }

  // 渲染用 markdown：流式中自愈未闭合标记，落定后用原文（落盘的文本才是事实）
  private mdForRender(): string {
    const raw: string = this.text();
    return this.streaming ? healStreamingMarkdown(raw) : raw;
  }

  // Markdown 选项对象必须复用：每次 build 新建对象会让 Markdown 组件的 @Monitor('options') 每次都
  // 触发（重新 deepMerge 主题 + 重新赋值 optionsClass ⇒ 整块 markdown 子树跟着重渲染），即使内容
  // 没变 —— 流式期间即表现为"整块一直在重绘/闪"。按输入指纹缓存，输入不变就复用同一实例。
  private optsKey: string = '';
  private optsCache: MarkdownOptions | null = null;

  private renderOptions(expanded: boolean): MarkdownOptions {
    const key: string = `${this.isDark ? 'd' : 'l'}|${expanded ? 'e' : 'p'}|${this.theme.accent}|${this.theme.accentDark}`;
    let out: MarkdownOptions | null = this.optsCache;
    if (out === null || this.optsKey !== key) {
      out = this.mdOptions(expanded);
      this.optsCache = out;
      this.optsKey = key;
    }
    return out;
  }

  // 文本变化 → 节流落盘（窗口内只安排一次）；流一停立刻落盘，不等窗口
  private onMessageChanged(): void {
    if (!this.streaming) {
      if (this.mdTimer >= 0) {
        clearTimeout(this.mdTimer);
        this.mdTimer = -1;
      }
      this.mdShown = this.mdForRender();
      return;
    }
    if (this.mdTimer >= 0) {
      return;
    }
    this.mdTimer = setTimeout((): void => {
      this.mdTimer = -1;
      this.mdShown = this.mdForRender();
    }, MD_THROTTLE_MS);
  }

  private text(): string {
    return textOfParts(this.message.parts);
  }

  // 资源文案取字符串（工程统一口径：resourceManager.getStringSync）
  private t(res: Resource): string {
    try {
      const host: common.Context = this.getUIContext().getHostContext() as common.Context;
      return host.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  private error(): string {
    return this.message.error !== undefined ? this.message.error : '';
  }

  private media(): DisplayPart[] {
    return mediaPartsOf(this.message.parts);
  }

  private collapsible(): boolean {
    return this.text().length > 240;
  }

  private trigger(): ResponseType {
    return this.selecting || this.text().length === 0 ? ResponseType.RightClick : ResponseType.LongPress;
  }

  private async doCopy(): Promise<void> {
    const ok: boolean = await copyTextToClipboard(this.getUIContext(), this.text());
    const msg: string = ok ? this.t($r('app.string.chat_msg_copied')) : this.t($r('app.string.chat_msg_copy_failed'));
    this.getUIContext().getPromptAction().showToast({ message: msg });
    if (ok) {
      this.copied = true;
    }
  }

  @Builder
  bubbleMenu() {
    Menu() {
      MenuItem({
        content: this.t($r('app.string.chat_msg_copy')),
        symbolStartIcon: new SymbolGlyphModifier($r('app.media.copy'))
      })
        .onClick((): void => {
          this.doCopy();
        })
      MenuItem({
        content: this.t($r('app.string.chat_msg_select')),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.smart_selection_area'))
      })
        .onClick((): void => {
          if (this.text().length > 0) {
            this.copied = false;
            this.selecting = true;
          }
        })
    }
  }

  // markdown 渲染选项：只覆盖 7378 features/chat/MessageParts.tsx 的 markdownStyles 已定义的项
  // （paragraph 16、h1 22 / h2 19 / h3 17、加粗、链接色），其余交库默认主题 —— 库内对 theme 做深合并，
  // 部分字段即可；暗色用同一份（文字色取本工程文本 token，随主题切换）。
  private mdOptions(expanded: boolean): MarkdownOptions {
    // 浅/深两套显式色：库按 darkMode 在 theme / darkTheme 之间二选一（deepMerge 各自默认主题），
    // 传同一份、只给资源 token 会让深色下的取色不稳定，故两套各自给显式色值。
    const lightInk: ResourceColor = '#182431';
    const darkInk: ResourceColor = '#FAFAFA';
    const lp: MarkdownFontStyle = { fontSize: 16, fontColor: lightInk };
    const l1: MarkdownFontStyle = { fontSize: 22, fontColor: lightInk, fontWeight: FontWeight.Bold };
    const l2: MarkdownFontStyle = { fontSize: 19, fontColor: lightInk, fontWeight: FontWeight.Bold };
    const l3: MarkdownFontStyle = { fontSize: 17, fontColor: lightInk, fontWeight: FontWeight.Bold };
    const lightHeads: MarkdownFontStyle[] = [l1, l2, l3];
    const lCode: CodeStyle = { backgroundColor: '#1C1917', fontSize: 13, borderRadius: 12 };
    const lSpan: CodeSpan = { backgroundColor: '#EEEAE2', borderRadius: 5 };
    const lQuote: BlockQuoteStyle = {
      backgroundColor: '#FFF0E5', driveColor: this.theme.accent, driveWidth: 3
    };
    const lHr: DriveStyle = { driveColor: '#E4DDD4' };
    const light: MarkdownTheme = {
      themeColor: lightInk,
      paragraphStyle: lp,
      headingStyle: lightHeads,
      linkColor: this.theme.accent,
      code: lCode,
      codeSpan: lSpan,
      blockQuoteStyle: lQuote,
      hrStyle: lHr
    };
    const dp: MarkdownFontStyle = { fontSize: 16, fontColor: darkInk };
    const d1: MarkdownFontStyle = { fontSize: 22, fontColor: darkInk, fontWeight: FontWeight.Bold };
    const d2: MarkdownFontStyle = { fontSize: 19, fontColor: darkInk, fontWeight: FontWeight.Bold };
    const d3: MarkdownFontStyle = { fontSize: 17, fontColor: darkInk, fontWeight: FontWeight.Bold };
    const darkHeads: MarkdownFontStyle[] = [d1, d2, d3];
    const dCode: CodeStyle = { backgroundColor: '#1C1917', fontSize: 13, borderRadius: 12 };
    const dSpan: CodeSpan = { backgroundColor: '#2A2723', borderRadius: 5 };
    const dQuote: BlockQuoteStyle = {
      backgroundColor: '#3B261B', driveColor: this.theme.accentDark, driveWidth: 3
    };
    const dHr: DriveStyle = { driveColor: '#37332E' };
    const dark: MarkdownTheme = {
      themeColor: darkInk,
      paragraphStyle: dp,
      headingStyle: darkHeads,
      linkColor: this.theme.accentDark,
      code: dCode,
      codeSpan: dSpan,
      blockQuoteStyle: dQuote,
      hrStyle: dHr
    };
    const opts: MarkdownOptions = {
      theme: light,
      darkTheme: dark,
      darkMode: this.isDark
    };
    if (!expanded) {
      opts.maxLines = 12;
    }
    return opts;
  }

  build() {
    Column() {
      if (this.selecting) {
        SelectionToolbar({
          inverted: false,
          copied: this.copied,
          isDark: this.isDark,
          theme: this.theme,
          onCopy: (): void => {
            this.doCopy();
          },
          onDone: (): void => {
            this.selecting = false;
          }
        })
      }
      if (this.last) {
        Text($r('app.string.chat_answer_label'))
          .fontSize(UiTokens.fsCaption)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ bottom: 4 })
      }
      if (this.error().length > 0) {
        Text($r('app.string.chat_answer_failed'))
          .fontSize(UiTokens.fsCaption)
          .fontColor($r('app.color.status_error'))
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 2 })
        Text(this.error())
          .fontSize(UiTokens.fsCaption)
          .fontColor($r('app.color.status_error'))
          .wordBreak(WordBreak.BREAK_ALL)
      } else if (this.text().length > 0) {
        if (this.selecting) {
          // 选择态：保留纯文本 Text —— 系统文本选择与 copyOption 只在这条路上可用，
          // 换成渲染组件会把「复制 / 选择文本」这条已验收能力打掉。
          Text(this.text())
            .fontSize(UiTokens.fsBody)
            .fontColor($r('app.color.input_text'))
            .lineHeight(21)
            .wordBreak(WordBreak.BREAK_WORD)
            .maxLines(this.expanded ? NO_LINE_LIMIT : 12)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .copyOption(CopyOptions.LocalDevice)
        } else {
          // 普通态：markdown 渲染（口径见 mdOptions 注释）；内容走节流副本（见 MD_THROTTLE_MS）
          Markdown({ content: this.mdShown, options: this.renderOptions(this.expanded) })
            .width('100%')
        }
        if (this.collapsible()) {
          Text(this.expanded ? $r('app.string.chat_answer_collapse') : $r('app.string.chat_answer_expand'))
            .fontSize(UiTokens.fsCaption)
            .fontColor(this.isDark ? this.theme.accentDark : this.theme.accent)
            .margin({ top: 4 })
            .onClick((): void => {
              this.expanded = !this.expanded;
            })
        }
      }
      // 该段自带媒体（图片 / 文件卡）
      if (this.media().length > 0) {
        Column() {
          MediaParts({ parts: this.media(), baseUrl: this.baseUrl })
        }
        .width('100%')
        .margin({ top: 8 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(UiTokens.cardRadius)
    .backgroundColor($r('app.color.card_surface'))
    .bindContextMenu(this.bubbleMenu(), this.trigger(), contextMenuOptions())
    .margin({ top: 6, bottom: 6 })
  }
}

// ============ 回合工具产出媒体行 ============
@Component
export struct MediaRow {
  @Prop parts: DisplayPart[] = [];
  @Prop baseUrl: string = '';
  // 文件/媒体清单默认收起：console 把它作为回合末尾的一项（ResponseArtifactList）按需展示，
  // 不是一直挂在下方的常驻块
  @State expanded: boolean = false;

  private t(res: Resource): string {
    try {
      const host: common.Context = this.getUIContext().getHostContext() as common.Context;
      return host.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  private headerText(): string {
    const n: string = this.parts.length.toString();
    const raw: string = this.t($r('app.string.chat_files_section'));
    return raw.length > 0 ? raw.replace('%d', n) : n;
  }

  build() {
    Column() {
      Row() {
        Text(this.headerText())
          .fontSize(UiTokens.fsSecondary)
          .fontColor($r('app.color.text_secondary'))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        Text(this.expanded ? $r('app.string.chat_answer_collapse') : $r('app.string.chat_answer_expand'))
          .fontSize(UiTokens.fsCaption)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick((): void => {
        // 展开/收起包在显式动画里（文件卡是"放大/缩小"，不是瞬跳）
        this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, (): void => {
          this.expanded = !this.expanded;
        });
      })
      if (this.expanded) {
        MediaParts({ parts: this.parts, baseUrl: this.baseUrl })
      }
    }
    .width('100%')
    .margin({ top: 8, bottom: 6 })
  }
}

// ============ 待发回合「正在生成…」占位行 ============
@Component
export struct PendingRow {
  build() {
    Column() {
      Text($r('app.string.chat_answer_pending'))
        .fontSize(UiTokens.fsSecondary)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ top: 6, bottom: 6 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}

// ============ 步骤组卡（思考 / 工具）============
// 折叠时不渲染子树（对齐 console 的 LazyAccordion destroy-on-close）。
function toolLabel(name: string | undefined): string {
  if (name === undefined || name.length === 0) {
    return '';
  }
  return name.replace(/_/g, ' ');
}

// 工具状态等级（对齐 7378 toolStateLabel）：0=调用（无结果无状态）/1=失败/2=完成
function toolStateLevel(m: DisplayMessage): number {
  const hasOutput: boolean = m.toolOutput !== undefined && m.toolOutput.length > 0;
  const state: string = m.toolState !== undefined ? m.toolState : '';
  if (!hasOutput && state.length === 0) {
    return 0;
  }
  if (/error|failed|denied|interrupted/i.test(state)) {
    return 1;
  }
  return 2;
}

// 合并连续同工具消息（对齐 7378 mergeToolMessages：同 callId 或同 name 或无名同 input 无 output）
export function mergeToolMessages(messages: DisplayMessage[]): DisplayMessage[] {
  const merged: DisplayMessage[] = [];
  for (const message of messages) {
    if (message.kind !== 'tool') {
      merged.push(message);
      continue;
    }
    const prev: DisplayMessage | null = merged.length > 0 ? merged[merged.length - 1] : null;
    if (prev !== null && prev.kind === 'tool') {
      const sameCall: boolean =
        (message.toolCallId !== undefined && message.toolCallId.length > 0
          && message.toolCallId === prev.toolCallId)
        || (message.toolName !== undefined && message.toolName.length > 0
          && message.toolName === prev.toolName)
        || (message.toolName === undefined && message.toolInput !== undefined
          && prev.toolInput !== undefined
          && (prev.toolOutput === undefined || prev.toolOutput.length === 0));
      if (sameCall) {
        const parts: DisplayPart[] = [];
        const seen: string[] = [];
        for (const p of prev.parts.concat(message.parts)) {
          const k: string = p.type === 'text' ? `t:${p.text !== undefined ? p.text : ''}`
            : `${p.type}:${p.url !== undefined ? p.url : ''}`;
          if (seen.indexOf(k) < 0) {
            seen.push(k);
            parts.push(p);
          }
        }
        const nm: DisplayMessage = {
          id: prev.id,
          role: prev.role,
          kind: 'tool',
          parts: parts,
          toolName: prev.toolName !== undefined ? prev.toolName : message.toolName,
          toolState: message.toolState !== undefined ? message.toolState : prev.toolState,
          toolCallId: prev.toolCallId !== undefined ? prev.toolCallId : message.toolCallId,
          toolInput: prev.toolInput !== undefined ? prev.toolInput : message.toolInput,
          toolOutput: message.toolOutput !== undefined ? message.toolOutput : prev.toolOutput
        };
        merged[merged.length - 1] = nm;
        continue;
      }
    }
    merged.push(message);
  }
  return merged;
}

@Component
export struct ProcessHeader {
  @Prop process: DisplayMessage[] = [];
  @Prop isDark: boolean = false;
  @Prop theme: ThemeSnapshot = ThemeManager.get().snapshot();
  // 生成中的过程组默认展开（对齐 console getCollapsedStepPresentation：generating → defaultOpen true）
  // 本组是否为「活动组」（正在生成）：活动组头部显示转圈，其工具行未出结果时显示进行中
  @Prop generating: boolean = false;
  // 展开态由页面持有：扁平化后组头与组内每行都是页面 List 的独立项
  @Prop expanded: boolean = false;
  onToggle: () => void = (): void => {};

  // 资源文案取字符串（工程统一口径：resourceManager.getStringSync）
  private t(res: Resource): string {
    try {
      const host: common.Context = this.getUIContext().getHostContext() as common.Context;
      return host.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  private accentColor(): string {
    return this.isDark ? this.theme.accentDark : this.theme.accent;
  }

  private merged(): DisplayMessage[] {
    return mergeToolMessages(this.process);
  }

  private summary(): string {
    const msgs: DisplayMessage[] = this.process;
    let tools: number = 0;
    let toolCalls: number = 0;
    let hasReasoning: boolean = false;
    for (const m of msgs) {
      if (m.kind === 'tool') {
        tools++;
        if (m.toolState === undefined || m.toolState.length === 0) {
          toolCalls++;
        }
      } else if (m.kind === 'reasoning') {
        hasReasoning = true;
      }
    }
    const effectiveTools: number = toolCalls > 0 ? toolCalls : tools;
    const parts: string[] = [];
    if (hasReasoning) {
      parts.push(this.t($r('app.string.chat_process_summary_think')));
    }
    if (effectiveTools > 0) {
      parts.push(this.t($r('app.string.chat_process_summary_tools')).replace('%d', effectiveTools.toString()));
    }
    if (parts.length === 0) {
      parts.push(this.t($r('app.string.chat_process_summary_mid')).replace('%d', msgs.length.toString()));
    }
    return parts.join(' · ');
  }

  build() {
    Column() {
      Row() {
        Image($r('app.media.activity'))
          .width(16).height(16)
          .fillColor(this.accentColor())
          .margin({ right: 8 })
        Column() {
          Text($r('app.string.chat_process_tool'))
            .fontSize(UiTokens.fsSecondary)
            .fontColor($r('app.color.text_secondary'))
            .fontWeight(FontWeight.Medium)
          Text(this.summary())
            .fontSize(UiTokens.fsCaption)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.generating) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(this.accentColor())
            .margin({ right: 6 })
        }
        Text(this.expanded ? '▲' : '▼')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .onClick((): void => {
        this.onToggle();
      })
      // 折叠时不构建子树（对齐 console LazyAccordion destroy-on-close）：官方 if/else 口径
      // 「分支变化时移除此前构建的所有子组件，再执行新分支的构建函数」——条件渲染控制的是
      // 组件的创建/布局阶段（对比 visibility 只控制是否参与布局渲染），收起即整棵子树不在树上。
    }
    .width('100%')
    .borderRadius(UiTokens.cardRadius)
    .backgroundColor($r('app.color.card_surface'))
    .borderWidth(1)
    .borderColor($r('app.color.line'))
    .margin({ top: 6, bottom: 6 })
  }
}

@Component
struct ProcessRow {
  @Prop @Watch('onMessageChanged') message: DisplayMessage = { id: '', role: 'assistant', kind: 'message', parts: [] };
  @Prop isDark: boolean = false;
  @Prop theme: ThemeSnapshot = ThemeManager.get().snapshot();
  // 本行所属过程组是否为「活动组」（正在生成）；同时作为"流式中"判据 → 渲染前自愈未闭合标记
  @Prop @Watch('onMessageChanged') generating: boolean = false;
  // 本行是否为组内末位（活动组里正在被写入的那条思考行 → 行首转圈）
  @Prop last: boolean = false;
  // 工具行：展开参数 / 结果详情；思考行：展开全文（长文本默认折叠）
  @State detailExpanded: boolean = false;
  // 喂给 Markdown 的节流文本（见 MD_THROTTLE_MS 注释）
  @State mdShown: string = '';
  private mdTimer: number = -1;

  // 资源文案取字符串（工程统一口径：resourceManager.getStringSync）
  private t(res: Resource): string {
    try {
      const host: common.Context = this.getUIContext().getHostContext() as common.Context;
      return host.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  // 渲染用 markdown：流式中自愈未闭合标记，落定后用原文（落盘的文本才是事实）
  private mdForRender(): string {
    const raw: string = this.text();
    return this.generating ? healStreamingMarkdown(raw) : raw;
  }

  // Markdown 选项对象必须复用（理由同 MessageRow.renderOptions）：每次 build 新建对象会触发
  // Markdown 的 @Monitor('options') → 整块子树重渲染，流式期间表现为"一直在重绘/闪"。
  private optsKey: string = '';
  private optsCache: MarkdownOptions | null = null;

  private renderReasoningOptions(expanded: boolean): MarkdownOptions {
    const key: string = `${this.isDark ? 'd' : 'l'}|${expanded ? 'e' : 'p'}|${this.theme.accent}|${this.theme.accentDark}`;
    let out: MarkdownOptions | null = this.optsCache;
    if (out === null || this.optsKey !== key) {
      out = this.mdReasoning(expanded);
      this.optsCache = out;
      this.optsKey = key;
    }
    return out;
  }

  aboutToAppear(): void {
    this.mdShown = this.mdForRender();
  }

  aboutToDisappear(): void {
    if (this.mdTimer >= 0) {
      clearTimeout(this.mdTimer);
      this.mdTimer = -1;
    }
  }

  // 文本变化 → 节流落盘（窗口内只安排一次）；流一停立刻落盘，不等窗口
  private onMessageChanged(): void {
    if (!this.generating) {
      if (this.mdTimer >= 0) {
        clearTimeout(this.mdTimer);
        this.mdTimer = -1;
      }
      this.mdShown = this.mdForRender();
      return;
    }
    if (this.mdTimer >= 0) {
      return;
    }
    this.mdTimer = setTimeout((): void => {
      this.mdTimer = -1;
      this.mdShown = this.mdForRender();
    }, MD_THROTTLE_MS);
  }

  private accentColor(): string {
    return this.isDark ? this.theme.accentDark : this.theme.accent;
  }

  private title(): ResourceStr {
    if (this.message.kind === 'reasoning') {
      return $r('app.string.chat_process_thinking_label');
    }
    if (this.message.kind === 'tool') {
      const name: string = toolLabel(this.message.toolName);
      return name.length > 0 ? name : $r('app.string.chat_tool_default');
    }
    return $r('app.string.chat_process_mid');
  }

  private stateLevel(): number {
    return toolStateLevel(this.message);
  }

  // 行尾状态文案随执行态变：进行中（活动组且未出结果）/ 失败 / 完成。
  // 非活动组里的无结果工具行按「调用」呈现（对齐 console：非活动组状态一律视为已完成）。
  private stateLabel(): ResourceStr {
    const lv: number = this.stateLevel();
    if (lv === 0) {
      return this.generating ? $r('app.string.chat_process_running') : $r('app.string.chat_process_call');
    }
    if (lv === 1) {
      return $r('app.string.chat_process_failed');
    }
    return $r('app.string.chat_process_done');
  }

  private stateColor(): ResourceColor {
    const lv: number = this.stateLevel();
    if (lv === 1) {
      return $r('app.color.status_error');
    }
    if (lv === 2) {
      return $r('app.color.text_secondary');
    }
    return $r('app.color.text_tertiary');
  }

  // 思考行：整行以灰底卡片呈现（对齐 console 的 OperateCard），与工具行区分
  private thinking(): boolean {
    return this.message.kind === 'reasoning';
  }

  // 行首图标槽（对齐 console ToolCardShell 的 summary 图标）：思考行 = 灯泡；
  // 工具行 = 成功对勾 / 失败叉（console 的 toolCallIconSuccess / toolCallIconError）
  private leadIcon(): Resource {
    if (this.message.kind === 'reasoning') {
      return $r('app.media.lightbulb');
    }
    return this.stateLevel() === 1 ? $r('app.media.circle_x') : $r('app.media.circle_check');
  }

  private leadIconColor(): ResourceColor {
    return this.stateLevel() === 1 ? $r('app.color.status_error') : this.accentColor();
  }

  // 行首标题：调用中追加「处理中...」（对齐 console：{title} {t("tool.loading")}）
  private leadTitle(): ResourceStr {
    if (!this.running()) {
      return this.title();
    }
    const loading: string = this.t($r('app.string.chat_tool_loading'));
    if (this.message.kind === 'tool') {
      const name: string = toolLabel(this.message.toolName);
      const base: string = name.length > 0 ? name : this.t($r('app.string.chat_tool_default'));
      return `${base} ${loading}`;
    }
    return `${this.t($r('app.string.chat_process_thinking_label'))} ${loading}`;
  }

  // 调用中（对齐 console ToolCardShell：status === "calling" && isStreaming）→ 行首转圈：
  // ① 活动组里尚未返回结果的工具行；② 活动组末位那条（正在被写入的思考行）。
  private running(): boolean {
    if (!this.generating) {
      return false;
    }
    if (this.message.kind === 'tool') {
      return this.stateLevel() === 0;
    }
    return this.message.kind === 'reasoning' && this.last;
  }

  // 思考行的 markdown 选项：字号与配色压到次级（浅/深各自给显式色，理由见 MessageRow.mdOptions）。
  // 生成中（活动组）不截断 —— 思考期间要能看全；该组结束后回到 6 行预览 + 「展开全文」。
  private mdReasoning(expanded: boolean): MarkdownOptions {
    const lightInk: ResourceColor = '#666666';
    const darkInk: ResourceColor = '#B3B3B3';
    const size: number = UiTokens.fsCaption;
    const l1: MarkdownFontStyle = { fontSize: size + 2, fontColor: lightInk, fontWeight: FontWeight.Bold };
    const d1: MarkdownFontStyle = { fontSize: size + 2, fontColor: darkInk, fontWeight: FontWeight.Bold };
    const light: MarkdownTheme = {
      themeColor: lightInk,
      paragraphStyle: { fontSize: size, fontColor: lightInk },
      headingStyle: [l1, l1, l1],
      linkColor: this.theme.accent,
      code: { backgroundColor: '#1C1917', fontSize: size - 1, borderRadius: 10 },
      codeSpan: { backgroundColor: '#EEEAE2', borderRadius: 4 },
      blockQuoteStyle: { backgroundColor: '#F1F3F5', driveColor: '#999999', driveWidth: 3 },
      hrStyle: { driveColor: '#E4DDD4' }
    };
    const dark: MarkdownTheme = {
      themeColor: darkInk,
      paragraphStyle: { fontSize: size, fontColor: darkInk },
      headingStyle: [d1, d1, d1],
      linkColor: this.theme.accentDark,
      code: { backgroundColor: '#1C1917', fontSize: size - 1, borderRadius: 10 },
      codeSpan: { backgroundColor: '#2A2723', borderRadius: 4 },
      blockQuoteStyle: { backgroundColor: '#2A2723', driveColor: '#8A8A8A', driveWidth: 3 },
      hrStyle: { driveColor: '#37332E' }
    };
    const opts: MarkdownOptions = { theme: light, darkTheme: dark, darkMode: this.isDark };
    if (!expanded) {
      opts.maxLines = 6;
    }
    return opts;
  }

  private text(): string {
    return textOfParts(this.message.parts);
  }

  private toolDetailText(which: string): string {
    if (which === 'input') {
      return this.message.toolInput !== undefined ? this.message.toolInput : '';
    }
    return this.message.toolOutput !== undefined ? this.message.toolOutput : '';
  }

  private detailCollapsible(): boolean {
    const a: number = this.message.toolInput !== undefined ? this.message.toolInput.length : 0;
    const b: number = this.message.toolOutput !== undefined ? this.message.toolOutput.length : 0;
    return a + b > 420;
  }

  // 思考行长文本默认折叠（超出约 200 字给「展开全文 / 收起」）
  private textCollapsible(): boolean {
    return this.message.kind !== 'tool' && this.text().length > 200;
  }

  @Builder
  ToolDetailBlock(which: string) {
    if (this.toolDetailText(which).length > 0) {
      Column() {
        Text(which === 'input' ? $r('app.string.chat_tool_input_label') : $r('app.string.chat_tool_output_label'))
          .fontSize(UiTokens.fsCaption)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ bottom: 2 })
        Text(this.toolDetailText(which))
          .fontSize(UiTokens.fsCaption)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(18)
          .wordBreak(WordBreak.BREAK_ALL)
          .maxLines(this.detailExpanded ? NO_LINE_LIMIT : 6)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(8)
      .borderRadius(UiTokens.chipRadius)
      .backgroundColor($r('app.color.card_bg'))
      .margin({ top: 6 })
    }
  }

  // 行内容：工具行 = 参数/输出详情（默认收起）；思考行 = markdown 正文。
  // 思考正文套一层带左竖线的块（对齐 console：SDK OperateCard 的 LineBody = 左侧 1px 竖线 +
  // 内容内缩），灰底由外层卡片承载。
  @Builder
  ProcessContent() {
    if (this.message.kind === 'tool') {
      // 默认收起：展开态才渲染参数 / 输出两块详情（对齐 console 的工具卡，收起时不留大段正文）
      if (this.detailExpanded) {
        this.ToolDetailBlock('input')
        this.ToolDetailBlock('output')
      }
      if (this.detailCollapsible()) {
        Text(this.detailExpanded ? $r('app.string.chat_tool_collapse') : $r('app.string.chat_tool_view_full'))
          .fontSize(UiTokens.fsCaption)
          .fontColor(this.isDark ? this.theme.accentDark : this.theme.accent)
          .margin({ top: 4 })
      }
    } else {
      // 思考行：与 console 一致走 markdown 渲染（console 的 HostMessage 对任何 content 的
      // text 项都用 DeferredMarkdown），不再把思考内容当生硬纯文本；配色压到次级灰。
      // 生成中不截断（思考期间展示全部），结束后回到 6 行 + 「展开全文」。
      // 内容走节流副本（见 MD_THROTTLE_MS）：思考过程逐分片刷进来时不重起解析任务。
      Column() {
        Markdown({ content: this.mdShown, options: this.renderReasoningOptions(this.detailExpanded || this.generating) })
          .width('100%')
      }
      .width('100%')
      .padding({ left: 16 })
      .border({ width: { left: 1 }, color: $r('app.color.line') })
      .margin({ top: 6 })
      if (this.textCollapsible() && !this.generating) {
        Text(this.detailExpanded ? $r('app.string.chat_answer_collapse') : $r('app.string.chat_answer_expand'))
          .fontSize(UiTokens.fsCaption)
          .fontColor(this.isDark ? this.theme.accentDark : this.theme.accent)
          .margin({ top: 4 })
          .onClick((): void => {
            this.detailExpanded = !this.detailExpanded;
          })
      }
    }
  }

  build() {
    Row() {
      // 行首图标槽：调用中转圈，其余按状态给图标（转圈与图标同一位置交替，不额外占位）
      if (this.running()) {
        LoadingProgress()
          .width(15).height(15)
          .color(this.accentColor())
          .margin({ right: 8 })
      } else {
        Image(this.leadIcon())
          .width(15).height(15)
          .fillColor(this.leadIconColor())
          .margin({ right: 8 })
      }
      Column() {
        Row() {
          Text(this.leadTitle())
            .fontSize(UiTokens.fsSecondary)
            .fontColor($r('app.color.text_secondary'))
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
          // 调用中不叠状态标签（对齐 console：isLoading 时不显示 badges，加载态由转圈 + 「处理中...」表达）
          if (this.message.kind === 'tool' && !this.running()) {
            Row({ space: 4 }) {
              Text(this.stateLabel())
                .fontSize(UiTokens.fsCaption)
                .fontColor(this.stateColor())
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(6)
                .backgroundColor($r('app.color.card_bg'))
            }
            .alignItems(VerticalAlign.Center)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        this.ProcessContent()
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    // 思考行整体套灰底卡片（对齐 console：OperateCard 展开态 = colorFillTertiary 灰底 + 大圆角），
    // 与工具行（无底色）区分开，一眼能看出"这段是模型在思考"
    .padding(this.thinking() ? { left: 12, right: 12, top: 8, bottom: 8 } : { top: 10, bottom: 10 })
    .borderRadius(this.thinking() ? 10 : 0)
    .backgroundColor(this.thinking() ? $r('app.color.card_bg') : Color.Transparent)
    .margin({ top: this.thinking() ? 6 : 0 })
    // 工具行：点整行展开/收起参数与输出（详情块默认收起，切换必须挂在这一层；
    // 此前只画出开关文案、没挂点击，点了没有任何反应）
    .onClick((): void => {
      if (this.message.kind === 'tool' && this.detailCollapsible()) {
        this.detailExpanded = !this.detailExpanded;
      }
    })
  }
}

// ============ 行分发器 ============
// 一个 ConversationRow → 一个 ListItem 的子树。行数据经 @ObjectLink 接收：流式期间页面把新数据
// 赋到同一行对象上，本组件原地重渲染（ForEach 键不变 ⇒ 不重建子树，不闪、不打断滚动与展开态）。
@Component
export struct ChatRow {
  @ObjectLink row: ConversationRow;
  @Prop isDark: boolean = false;
  @Prop theme: ThemeSnapshot = ThemeManager.get().snapshot();
  @Prop baseUrl: string = '';
  // 过程组展开/收起：扁平化后组内每行都是页面 List 的独立项，展开态必须由页面决定
  onToggleSteps: (key: string) => void = (): void => {};

  build() {
    Column() {
      if (this.row.kind === 'user') {
        UserRow({
          message: this.row.messages[0], isDark: this.isDark, theme: this.theme, baseUrl: this.baseUrl
        })
      } else if (this.row.kind === 'message') {
        // 空内容的消息行不出卡（数据层已过滤，这里再兜一层：卡底色在深色下会把空行显成一张空白卡）
        if (rowHasVisibleContent(this.row.messages[0])) {
          MessageRow({
            message: this.row.messages[0], streaming: this.row.pending, last: this.row.last,
            isDark: this.isDark, theme: this.theme, baseUrl: this.baseUrl
          })
        }
      } else if (this.row.kind === 'stepsHeader') {
        ProcessHeader({
          process: this.row.messages, isDark: this.isDark, theme: this.theme,
          generating: this.row.generating,
          expanded: this.row.expanded === true,
          onToggle: (): void => {
            this.onToggleSteps(this.row.groupKey !== undefined ? this.row.groupKey : '');
          }
        })
      } else if (this.row.kind === 'proc') {
        ProcessRow({
          message: this.row.messages[0], isDark: this.isDark, theme: this.theme,
          generating: this.row.generating,
          last: this.row.last
        })
      } else if (this.row.kind === 'media') {
        MediaRow({ parts: this.row.parts, baseUrl: this.baseUrl })
      } else {
        PendingRow()
      }
    }
    .width('100%')
    .padding({ left: UiTokens.pageHMargin, right: UiTokens.pageHMargin })
  }
}
