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
  DisplayMessage, DisplayPart, textOfParts, partsTextLen
} from '../services/ChatDetailService';
import { ThemeSnapshot, ThemeManager } from '../theme/ThemeManager';
import { UiTokens } from '../theme/UiTokens';
import { downloadToCache, saveToGallery, shareFile, safeNameOf } from '../services/MediaActions';
import { Markdown } from '../vendor/markdown/Index';
import { MarkdownOptions, MarkdownTheme, MarkdownFontStyle } from '../vendor/markdown/Index';
import { CodeStyle, CodeSpan, BlockQuoteStyle, DriveStyle } from '../vendor/markdown/src/main/ets/config/MarkdownTheme';
import { contextMenuOptions } from '../theme/MenuMaterial';

// ============ 扁平行模型 ============
// 会话被展平成行序列：List 的每个 ListItem 承载一行。key 只由稳定身份构成（不含文本长度等
// 内容指纹）——已完成行的内容不再变 ⇒ 键不变 ⇒ ForEach 不重跑 itemGenerator、不重建子树；
// 唯一会随每帧变化的行由页面挂在 ForEach 之外直接构造。
export interface ConversationRow {
  key: string;                 // ForEach 键（唯一且稳定）
  kind: string;                // user | message | steps | media | pending
  turnId: string;              // 所属回合 id
  messages: DisplayMessage[];  // message / steps 行的消息；user 行为 [用户消息]
  parts: DisplayPart[];        // media 行的媒体分片
  pending: boolean;            // 所属回合是否在途（过程组生成中默认展开 / message 是否显示「最终回复」）
  expanded?: boolean;          // 过程组（stepsHeader）当前是否展开（展开态由页面持有）
  groupKey?: string;           // 过程组的稳定键（turnId:块序号），用于页面切换展开态
  last: boolean;               // message 行是否为该回合最终回复（显示「最终回复」标签）
  generating: boolean;         // steps 行是否为该回合正在生成的「活动组」（活动组显示转圈与进行中状态）
}

export const EMPTY_ROW: ConversationRow = {
  key: '', kind: '', turnId: '', messages: [], parts: [], pending: false, last: false, generating: false
};

// 展开态「不限行数」用的行数上限：不能用 maxLines(0) —— 真机实测该值被当作 0 行处理，
// 展开后文本反而整段不显示（Text 节点消失）。用一个足够大的整数表达「不限制」。
const NO_LINE_LIMIT: number = 100000;

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
  const previewPath: string = path.startsWith('/') ? path : `/${path}`;
  return `${baseUrl}/api/files/preview${previewPath}`;
}

function mediaPartsOf(parts: DisplayPart[]): DisplayPart[] {
  return parts.filter((p: DisplayPart): boolean => p.type !== 'text');
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

// 媒体类型图标（用文本符号：SymbolGlyph.fontColor 不接受 string 主题色）
function mediaGlyph(type: string): string {
  if (type === 'video') {
    return '🎬';
  }
  if (type === 'audio') {
    return '🎵';
  }
  if (type === 'image') {
    return '🖼';
  }
  return '📄';
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

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
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

  private fileNameOf(): string {
    const segs: string[] = this.urlOf().split('/');
    const last: string = segs.length > 0 ? segs[segs.length - 1] : '';
    const raw: string = this.part.name !== undefined && this.part.name.length > 0 ? this.part.name : last;
    return safeNameOf(raw, this.part.type);
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

  // 媒体长按菜单：保存到相册（安全控件）+ 系统分享（对齐 7378 mediaActions 两项）
  @Builder
  mediaMenu() {
    Column() {
      if (this.part.type === 'image' || this.part.type === 'video') {
        SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.DOWNLOAD })
          .iconSize(20)
          .onClick(this.handleSave)
        Divider().color($r('app.color.card_bg')).strokeWidth(1)
      }
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

  // base64 data URL → PixelMap（ArkTS Image 不直读 data URL；对齐 7378 base64 source 分支）
  private async decodeDataUrl(url: string): Promise<void> {
    const comma: number = url.indexOf(',');
    if (comma < 0) {
      return;
    }
    try {
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(url.slice(comma + 1));
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
      Text(mediaGlyph(this.part.type))
        .fontSize(20)
        .margin({ right: 10 })
      Column() {
        Text(this.part.name !== undefined && this.part.name.length > 0 ? this.part.name : this.part.type)
          .fontSize(UiTokens.fsSecondary)
          .fontColor($r('app.color.text_primary_strong'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.part.type)
          .fontSize(UiTokens.fsCaption)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor($r('app.color.card_bg'))
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
  @Prop message: DisplayMessage = { id: '', role: 'assistant', kind: 'message', parts: [] };
  @Prop last: boolean = false;
  @Prop isDark: boolean = false;
  @Prop theme: ThemeSnapshot = ThemeManager.get().snapshot();
  @Prop baseUrl: string = '';
  @State expanded: boolean = false;
  @State selecting: boolean = false;
  @State copied: boolean = false;

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
          // 普通态：markdown 渲染（口径见 mdOptions 注释）
          Markdown({ content: this.text(), options: this.mdOptions(this.expanded) })
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
        this.expanded = !this.expanded;
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
  @Prop message: DisplayMessage = { id: '', role: 'assistant', kind: 'message', parts: [] };
  @Prop isDark: boolean = false;
  @Prop theme: ThemeSnapshot = ThemeManager.get().snapshot();
  // 本行所属过程组是否为「活动组」（正在生成）
  @Prop generating: boolean = false;
  // 工具行：展开参数 / 结果详情；思考行：展开全文（长文本默认折叠）
  @State detailExpanded: boolean = false;

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

  // 进行中：活动组里尚未返回结果的工具行 → 行尾转圈
  private running(): boolean {
    return this.message.kind === 'tool' && this.generating && this.stateLevel() === 0;
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

  build() {
    Row() {
      Image($r('app.media.circle_check'))
        .width(15).height(15)
        .fillColor(this.accentColor())
        .margin({ right: 8 })
      Column() {
        Row() {
          Text(this.title())
            .fontSize(UiTokens.fsSecondary)
            .fontColor($r('app.color.text_secondary'))
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
          if (this.message.kind === 'tool') {
            Row({ space: 4 }) {
              if (this.running()) {
                // 进行中：转圈（LoadingProgress，官方 API 8+，color 设前景色）
                LoadingProgress()
                  .width(14)
                  .height(14)
                  .color(this.accentColor())
              }
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
          Text(this.text())
            .fontSize(UiTokens.fsCaption)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(18)
            .wordBreak(WordBreak.BREAK_ALL)
            .maxLines(this.detailExpanded ? NO_LINE_LIMIT : 6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.textCollapsible()) {
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
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
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
// 一个 ConversationRow → 一个 ListItem 的子树。挂载在 ListItem 内；页面把除末行外的行放进
// ForEach（键稳定 ⇒ 不重建），末行直接构造本组件（每帧经 @Prop 拿到新行 ⇒ 按常规更新路径刷新，
// 不重建子树，展开 / 选择态不被打断）。
@Component
export struct ChatRow {
  @Prop row: ConversationRow = EMPTY_ROW;
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
        MessageRow({
          message: this.row.messages[0], last: this.row.last, isDark: this.isDark,
          theme: this.theme, baseUrl: this.baseUrl
        })
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
          generating: this.row.generating
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
