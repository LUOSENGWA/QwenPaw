/*
 * 工作台模块 · 扩展 —— 对齐 PR #7378 features/workbench/ExtensionsSettings.tsx。
 *   GET    /api/plugins                       → [{id,name,version,description,plugin_type,loaded,...}]
 *   GET    /api/pawapps                       → {apps:[{id,name,version,description,status,...}]}
 *   POST   /api/plugins/install               → {source:<ZIP URL>, force:false}
 *   DELETE /api/plugins/{id}                  → 卸载
 *   POST   /api/market/search                 → {query, provider_pages, limit, lang} → {results, errors}
 *   POST   /api/skills/hub/install/start      → {bundle_url, version, enable:true} → {task_id}
 *   GET    /api/skills/hub/install/status/{id} → {status}（安装进度轮询）
 * 两组取数任一 404 → 该组显示「当前 QwenPaw 不支持」；两组都 404 才整页报不支持。
 *
 * 结构对齐 7378：Skill 市场（搜索 + 安装）→ App Center（点开 pawapp 详情）→ 已安装扩展（URL 安装 + 卸载）。
 */

import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { doRequest, jsonArrayOf, jsonOf } from '../services/ConnectionService';
import { QpConnection, loadConnection } from '../services/ConnectionStore';
import { IosGroup, IosRow } from './IosList';
import { FieldDef, FieldSheet, fieldDef } from './FieldSheet';
import { ModuleEmpty, ModuleError, ModuleFooter, ModuleLoading } from './ModuleStates';
import { SheetGate, moduleSheetOptions } from './SheetGate';
import { requestPawApp } from '../services/AppEvents';
import { UiTokens } from '../theme/UiTokens';

import { isDarkMode, accentColor } from '../theme/Accent';

const PATH_PLUGINS: string = '/plugins';
const PATH_PAWAPPS: string = '/pawapps';

const MODE_NONE: string = '';
const MODE_INSTALL: string = 'install';

// 安装轮询：每次 500ms，最多 120 次（约 60s，对齐 7378 waitForInstall）
const POLL_INTERVAL_MS: number = 500;
const POLL_MAX: number = 120;

class PluginRow {
  id: string = '';
  name: string = '';
  version: string = '';
  description: string = '';
  pluginType: string = '';
  loaded: boolean = false;
  isApp: boolean = false;
}

class AppRow {
  id: string = '';
  name: string = '';
  version: string = '';
  description: string = '';
  status: string = '';
}

class MarketRow {
  source: string = '';
  slug: string = '';
  name: string = '';
  description: string = '';
  sourceUrl: string = '';
  version: string = '';
  author: string = '';
}

@Component
export struct ModuleExtensions {
  @State plugins: PluginRow[] = [];
  @State apps: AppRow[] = [];
  @State pluginsOk: boolean = false;
  @State appsOk: boolean = false;
  @State loaded: boolean = false;
  @State error: string = '';
  @State busy: boolean = false;
  @State query: string = '';
  @State searching: boolean = false;
  @State searched: boolean = false;
  @State results: MarketRow[] = [];
  // 正在安装的市场项 slug（行上显示「安装中」；非空时屏蔽重复安装）
  @State installing: string = '';
  @State sheetShown: boolean = false;
  @State sheetMode: string = MODE_NONE;
  @State isDark: boolean = false;
  private gate: SheetGate = new SheetGate();
  private conn: QpConnection | null = null;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.isDark = isDarkMode(ctx);
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

  private accent(): ResourceColor {
    return accentColor(this.isDark);
  }

  private async send(path: string, method: http.RequestMethod,
    body: string | null): Promise<http.HttpResponse> {
    const c: QpConnection | null = this.conn;
    if (c === null) {
      throw new Error(this.t($r('app.string.module_not_connected')));
    }
    return doRequest(`${c.baseUrl}/api${path}`, method, body,
      c.token.length > 0 ? c.token : null, c.agentId);
  }

  // 两组取数并发（旧写法顺序 await，慢一倍）：任一 404 只降级该组，两组都不可用才整页报不支持
  private async load(): Promise<void> {
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const c: QpConnection | null = await loadConnection(ctx);
    if (c === null) {
      this.error = this.t($r('app.string.module_not_connected'));
      this.loaded = true;
      return;
    }
    this.conn = c;
    try {
      const pluginsReq: Promise<http.HttpResponse> =
        this.send(PATH_PLUGINS, http.RequestMethod.GET, null);
      const appsReq: Promise<http.HttpResponse> =
        this.send(PATH_PAWAPPS, http.RequestMethod.GET, null);
      const p: http.HttpResponse = await pluginsReq;
      this.pluginsOk = p.responseCode >= 200 && p.responseCode < 300;
      this.plugins = this.pluginsOk ? this.parseList(p) : [];

      const a: http.HttpResponse = await appsReq;
      this.appsOk = a.responseCode >= 200 && a.responseCode < 300;
      this.apps = this.appsOk ? this.parseApps(a) : [];

      if (!this.pluginsOk && !this.appsOk) {
        this.error = this.t($r('app.string.module_ext_unsupported'));
      } else {
        this.error = '';
      }
    } catch (e) {
      this.error = (e as Error).message;
    }
    this.loaded = true;
  }

  private parseList(resp: http.HttpResponse): PluginRow[] {
    const out: PluginRow[] = [];
    for (const item of jsonArrayOf(resp)) {
      const r: Record<string, Object> = item as Record<string, Object>;
      const row: PluginRow = new PluginRow();
      row.id = typeof r['id'] === 'string' ? r['id'] as string : '';
      row.name = typeof r['name'] === 'string' ? r['name'] as string : row.id;
      row.version = typeof r['version'] === 'string' ? r['version'] as string : '';
      row.description = typeof r['description'] === 'string' ? r['description'] as string : '';
      row.pluginType = typeof r['plugin_type'] === 'string' ? r['plugin_type'] as string : 'plugin';
      row.loaded = r['loaded'] === true;
      row.isApp = row.pluginType === 'app';
      if (row.id.length > 0) {
        out.push(row);
      }
    }
    return out;
  }

  private parseApps(resp: http.HttpResponse): AppRow[] {
    const out: AppRow[] = [];
    const apps: Object = jsonOf(resp)['apps'];
    if (apps === undefined || apps === null || !Array.isArray(apps)) {
      return out;
    }
    for (const item of apps as Object[]) {
      const r: Record<string, Object> = item as Record<string, Object>;
      const row: AppRow = new AppRow();
      row.id = typeof r['id'] === 'string' ? r['id'] as string : '';
      row.name = typeof r['name'] === 'string' ? r['name'] as string : row.id;
      row.version = typeof r['version'] === 'string' ? r['version'] as string : '';
      row.description = typeof r['description'] === 'string' ? r['description'] as string : '';
      row.status = typeof r['status'] === 'string' ? r['status'] as string : '';
      if (row.id.length > 0) {
        out.push(row);
      }
    }
    return out;
  }

  private openInstall(): void {
    this.sheetMode = MODE_INSTALL;
    if (this.gate.request()) {
      this.sheetShown = true;
    }
  }

  private closeSheet(): void {
    this.gate.beginClose();
    this.sheetShown = false;
  }

  private installDefs(): FieldDef[] {
    return [fieldDef('source', this.t($r('app.string.module_ext_source')), 'text', true, '',
      this.t($r('app.string.module_ext_source_help')))];
  }

  // 安装（URL）：载荷对齐 7378 —— {source:<ZIP URL>, force:false}
  private async install(values: Record<string, Object>): Promise<void> {
    const raw: Object = values['source'];
    const source: string = typeof raw === 'string' ? (raw as string).trim() : '';
    if (source.length === 0) {
      return;
    }
    const body: Record<string, Object> = {};
    body['source'] = source;
    body['force'] = false;
    const resp: http.HttpResponse = await this.send('/plugins/install', http.RequestMethod.POST,
      JSON.stringify(body));
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      throw new Error(`HTTP ${resp.responseCode}`);
    }
    this.toast(this.t($r('app.string.module_ext_installed')));
    await this.load();
  }

  // 卸载：点行 → 确认对话框（对齐 7378 removePlugin）
  private confirmUninstall(row: PluginRow): void {
    if (this.busy) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: this.t($r('app.string.module_ext_uninstall_confirm')),
      message: row.version.length > 0 ? `${row.name} · ${row.version}` : row.name,
      primaryButton: {
        value: this.t($r('app.string.common_cancel')),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: this.t($r('app.string.module_ext_uninstall_action')),
        fontColor: $r('app.color.status_error'),
        action: (): void => {
          this.uninstall(row.id);
        }
      }
    });
  }

  private async uninstall(id: string): Promise<void> {
    if (this.busy || id.length === 0) {
      return;
    }
    this.busy = true;
    try {
      const resp: http.HttpResponse = await this.send(`/plugins/${encodeURIComponent(id)}`,
        http.RequestMethod.DELETE, null);
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      this.toast(this.t($r('app.string.module_ext_uninstalled')));
      await this.load();
    } catch (e) {
      this.toast(`${this.t($r('app.string.module_ext_failed'))}：${(e as Error).message}`);
    } finally {
      this.busy = false;
    }
  }

  // Skill 市场搜索（7378 search：provider_pages 传空、limit 20、lang 跟随内容语言）
  private async search(): Promise<void> {
    const q: string = this.query.trim();
    if (q.length === 0 || this.searching) {
      return;
    }
    this.searching = true;
    try {
      const body: Record<string, Object> = {};
      body['query'] = q;
      const pages: Record<string, Object> = {};
      body['provider_pages'] = pages;
      body['limit'] = 20;
      body['lang'] = 'zh-CN';
      const resp: http.HttpResponse = await this.send('/market/search',
        http.RequestMethod.POST, JSON.stringify(body));
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      const data: Record<string, Object> = jsonOf(resp);
      this.results = this.parseMarket(data['results']);
      this.searched = true;
      // 无结果但有 provider 报错时透出原因（对齐 7378：搜索未完成 → 列出错误）
      if (this.results.length === 0) {
        const messages: string = this.marketErrors(data['errors']);
        if (messages.length > 0) {
          this.getUIContext().showAlertDialog({
            title: this.t($r('app.string.module_ext_search_incomplete')),
            message: messages
          });
        }
      }
    } catch (e) {
      this.getUIContext().showAlertDialog({
        title: this.t($r('app.string.module_ext_search_failed')),
        message: (e as Error).message
      });
    } finally {
      this.searching = false;
    }
  }

  private parseMarket(value: Object): MarketRow[] {
    const out: MarketRow[] = [];
    if (value === undefined || value === null || !Array.isArray(value)) {
      return out;
    }
    for (const item of value as Object[]) {
      const r: Record<string, Object> = item as Record<string, Object>;
      const row: MarketRow = new MarketRow();
      row.source = typeof r['source'] === 'string' ? r['source'] as string : '';
      row.slug = typeof r['slug'] === 'string' ? r['slug'] as string : '';
      row.name = typeof r['name'] === 'string' ? r['name'] as string : row.slug;
      row.description = typeof r['description'] === 'string' ? r['description'] as string : '';
      row.sourceUrl = typeof r['source_url'] === 'string' ? r['source_url'] as string : '';
      row.version = typeof r['version'] === 'string' ? r['version'] as string : '';
      row.author = typeof r['author'] === 'string' ? r['author'] as string : '';
      if (row.slug.length > 0) {
        out.push(row);
      }
    }
    return out;
  }

  // provider 报错列表 → 换行拼接（对齐 7378：errors.map(e => e.message).join("\n")）
  private marketErrors(value: Object): string {
    if (value === undefined || value === null || !Array.isArray(value)) {
      return '';
    }
    const lines: string[] = [];
    for (const item of value as Object[]) {
      const r: Record<string, Object> = item as Record<string, Object>;
      const msg: string = typeof r['message'] === 'string' ? r['message'] as string : '';
      if (msg.length > 0) {
        lines.push(msg);
      }
    }
    return lines.join('\n');
  }

  private confirmInstallSkill(item: MarketRow): void {
    if (this.installing.length > 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: this.t($r('app.string.module_ext_install_confirm')),
      message: item.description.length > 0 ? item.description : item.name,
      primaryButton: {
        value: this.t($r('app.string.common_cancel')),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: this.t($r('app.string.module_ext_install_action')),
        action: (): void => {
          this.startInstall(item);
        }
      }
    });
  }

  // 市场安装：POST /skills/hub/install/start → 轮询 /skills/hub/install/status/{task_id}
  private startInstall(item: MarketRow): void {
    this.installing = item.slug;
    const body: Record<string, Object> = {};
    body['bundle_url'] = item.sourceUrl;
    body['version'] = item.version;
    body['enable'] = true;
    this.send('/skills/hub/install/start', http.RequestMethod.POST, JSON.stringify(body))
      .then((resp: http.HttpResponse): void => {
        if (resp.responseCode < 200 || resp.responseCode >= 300) {
          this.finishInstall(`${this.t($r('app.string.module_ext_failed'))}（HTTP ${resp.responseCode}）`);
          return;
        }
        const data: Record<string, Object> = jsonOf(resp);
        const taskId: string = typeof data['task_id'] === 'string' ? data['task_id'] as string : '';
        if (taskId.length === 0) {
          this.finishInstall(this.t($r('app.string.module_ext_skill_installed')));
          return;
        }
        this.pollInstall(taskId, 0);
      })
      .catch((e: Error): void => {
        this.finishInstall(`${this.t($r('app.string.module_ext_failed'))}：${e.message}`);
      });
  }

  private pollInstall(taskId: string, attempt: number): void {
    if (attempt >= POLL_MAX) {
      this.finishInstall(this.t($r('app.string.module_ext_install_timeout')));
      return;
    }
    this.send(`/skills/hub/install/status/${encodeURIComponent(taskId)}`,
      http.RequestMethod.GET, null)
      .then((resp: http.HttpResponse): void => {
        if (resp.responseCode !== 200) {
          this.schedulePoll(taskId, attempt);
          return;
        }
        const data: Record<string, Object> = jsonOf(resp);
        const status: string = typeof data['status'] === 'string' ? data['status'] as string : '';
        if (status === 'completed' || status === 'success') {
          this.finishInstall(this.t($r('app.string.module_ext_skill_installed')));
          return;
        }
        if (status === 'failed' || status === 'cancelled') {
          const msg: string = typeof data['error'] === 'string' ? data['error'] as string
            : (typeof data['message'] === 'string' ? data['message'] as string
              : this.t($r('app.string.module_ext_failed')));
          this.finishInstall(msg);
          return;
        }
        this.schedulePoll(taskId, attempt);
      })
      .catch((): void => {
        this.schedulePoll(taskId, attempt);
      });
  }

  private schedulePoll(taskId: string, attempt: number): void {
    setTimeout((): void => {
      this.pollInstall(taskId, attempt + 1);
    }, POLL_INTERVAL_MS);
  }

  private finishInstall(message: string): void {
    this.installing = '';
    this.toast(message);
  }

  private marketSubtitle(item: MarketRow): string {
    if (item.description.length > 0) {
      return item.description;
    }
    const author: string = item.author.length > 0 ? item.author : this.t($r('app.string.module_ext_unknown_author'));
    return item.source.length > 0 ? `${item.source} · ${author}` : author;
  }

  build() {
    Column() {
      if (this.error.length > 0) {
        ModuleError(this.error, (): void => {
          this.load();
        })
      } else if (!this.loaded) {
        ModuleLoading(this.t($r('app.string.module_loading')))
      } else {
        IosGroup({ title: this.t($r('app.string.module_ext_market')) }) {
          this.searchRow()
          ForEach(this.results, (item: MarketRow) => {
            IosRow({
              icon: $r('app.media.arrow_down_to_line'),
              label: item.name,
              subtitle: this.marketSubtitle(item),
              trailing: this.installing === item.slug
                ? this.t($r('app.string.module_ext_install_running'))
                : this.t($r('app.string.module_ext_install_action')),
              tappable: this.installing.length === 0,
              onPress: (): void => {
                this.confirmInstallSkill(item);
              }
            })
          }, (item: MarketRow) => `${item.source}:${item.slug}`)
          if (this.searched && this.results.length === 0) {
            ModuleEmpty($r('sys.symbol.magnifyingglass'),
              this.t($r('app.string.module_ext_search_empty')),
              this.t($r('app.string.module_ext_search_empty_hint')),
              true)
          }
        }

        IosGroup({ title: `${this.t($r('app.string.module_ext_group_apps'))} · ${this.apps.length}` }) {
          ForEach(this.apps, (row: AppRow) => {
            IosRow({
              icon: $r('app.media.layout_grid'),
              label: row.name,
              subtitle: row.description.length > 0 ? row.description
                : `${row.version}${row.status.length > 0 ? ' · ' + row.status : ''}`,
              trailing: this.t($r('app.string.module_ext_open')),
              tappable: true,
              // 打开该 App 的页面（对齐 7378：App Center 行 → pawapp/[id] 内嵌 Web）。
              // 本组件拿不到导航栈，交事件总线转给根页面 Index 去 pushPath。
              onPress: (): void => {
                requestPawApp(row.id);
              }
            })
          }, (row: AppRow) => row.id)
        }
        if (this.appsOk && this.apps.length === 0) {
          ModuleEmpty($r('app.media.layout_grid'),
            this.t($r('app.string.module_ext_apps_empty_title')),
            this.t($r('app.string.module_ext_apps_empty_subtitle')))
        }

        IosGroup({ title: `${this.t($r('app.string.module_ext_group_plugins'))} · ${this.plugins.length}` }) {
          IosRow({
            icon: $r('app.media.arrow_down_to_line'),
            label: this.t($r('app.string.module_ext_install_url')),
            subtitle: this.t($r('app.string.module_ext_install_hint')),
            tappable: this.pluginsOk && !this.busy,
            onPress: (): void => {
              this.openInstall();
            }
          })
          ForEach(this.plugins, (row: PluginRow) => {
            IosRow({
              icon: row.isApp ? $r('app.media.layout_grid') : $r('app.media.puzzle'),
              label: row.name,
              subtitle: row.version.length > 0
                ? `${row.pluginType} · ${row.version}` : row.description,
              trailing: row.loaded
                ? this.t($r('app.string.module_ext_running'))
                : this.t($r('app.string.module_ext_unloaded')),
              tappable: !this.busy,
              onPress: (): void => {
                this.confirmUninstall(row);
              }
            })
          }, (row: PluginRow) => row.id)
        }
        if (this.pluginsOk && this.plugins.length === 0 && this.apps.length === 0) {
          ModuleEmpty($r('app.media.puzzle'),
            this.t($r('app.string.module_ext_empty_title')),
            this.t($r('app.string.module_ext_empty_subtitle')))
        }
        ModuleFooter(this.t($r('app.string.module_ext_footer')))
      }
    }
    .width('100%')
    .bindSheet(this.sheetShown, this.sheetContent(),
      moduleSheetOptions(520, this.gate,
        (v: boolean): void => {
          this.sheetShown = v;
        }))
  }

  // 市场搜索行（与 IosRow 同底色/同高，右侧「搜索」动作）
  @Builder
  searchRow() {
    Column() {
      Row({ space: 8 }) {
        // 放大镜按口径用鸿蒙图标（sys.symbol）
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(17)
          .fontColor([$r('app.color.text_tertiary')])
        TextInput({ placeholder: $r('app.string.module_ext_search_placeholder'), text: $$this.query })
          .fontSize(UiTokens.fsBody)
          .caretColor(this.accent())
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.input_text'))
          .placeholderColor($r('app.color.placeholder'))
          .placeholderFont({ size: UiTokens.fsBody })
          .height(38)
          .layoutWeight(1)
          .enterKeyType(EnterKeyType.Search)
          .onSubmit((): void => {
            this.search();
          })
        Text(this.searching
          ? $r('app.string.module_ext_searching') : $r('app.string.module_ext_search'))
          .fontSize(UiTokens.fsSecondary)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.query.trim().length > 0
            ? this.accent() : $r('app.color.text_tertiary'))
          .onClick((): void => {
            this.search();
          })
      }
      .width('100%')
      .constraintSize({ minHeight: 60 })
      .padding({ left: UiTokens.cardPad, right: UiTokens.cardPad, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.card_surface'))
      Divider()
        .color($r('app.color.line'))
        .strokeWidth(0.5)
    }
    .width('100%')
  }

  @Builder
  sheetContent() {
    Column() {
      if (this.sheetMode === MODE_INSTALL) {
        FieldSheet({
          title: this.t($r('app.string.module_ext_install')),
          defs: this.installDefs(),
          initial: {} as Record<string, Object>,
          onSave: async (values: Record<string, Object>): Promise<void> => {
            await this.install(values);
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
