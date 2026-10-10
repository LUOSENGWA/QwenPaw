# QwenPaw 鸿蒙版（HarmonyOS NEXT）

bundleName：`io.agentscope.qwenpaw.mobile`（对齐上游 PR #7378 app.json）。
工程实体在本目录（纯 ASCII 路径）。
方案/契约/文档在 `../方案与设计/HarmonyQwenPaw/`。

## 构建（已验证 BUILD SUCCESSFUL）

```bash
cd <本目录> && env PATH=<工具链>/node24/bin:/usr/bin:/bin \
  JAVA_HOME=<工具链>/jdk21/<jdk-21> \
  DEVECO_CLI_CLT_PATH=<工具链>/command-line-tools \
  DEVECO_CLI_DATA_DIR=<工具链>/cli-data \
  DEVECO_CLI_DISABLE_TELEMETRY=1 \
  devecocli build --modules entry 2>&1 | tail -6
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`

## 平台/环境约束与踩坑记录

1. **路径（hvigor 00306003）**：工程路径仅允许 字母/数字/`-_.()空格@`，
   中文真实路径 0 task 即拦；symlink 方式未采用 → 直接放 ASCII 目录。
2. **inotify ENOSPC（2026-10-10 深查根治）**：内核 7.0.0-38 的 per-user
   inotify 配额（`user.max_inotify_watches`）本机实测有效上限 ≈5,600
   （名义 sysctl 65,536，strace 实证 `inotify_add_watch = -1 ENOSPC`）。
   hvigor daemon cluster worker 的 chokidar 在 Linux 硬编码 inotify 模式
   （`usePolling: isWindows()`），监视 hvigorfile require 树全部 .js
   （~1.2 万 watch）→ 必然打爆。
   **已修**：toolchain `hvigor/hvigor/src/base/daemon/cluster/watch-config-file.js`
   两处 watcher 改 `usePolling:!0`（=Windows 既有行为，1s 轮询；
   原版备份 `/tmp/watch-config-file.js.orig`）。
   可选系统级根治（需 sudo，不执行不影响构建）：
   `sudo sysctl -w user.max_inotify_watches=524288`（可持久化进 sysctl.d）。
3. 换工程路径后若 loader/缓存报旧绝对路径错误，清 `.hvigor/` 与
   `entry/build/` 重编（本次迁移未触发，增量 19 up-to-date 直接过）。

## 装机 / 冒烟

```bash
HDC=<CLT>/sdk/default/openharmony/toolchains/hdc
$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC shell aa force-stop io.agentscope.qwenpaw.mobile
$HDC shell aa start -b io.agentscope.qwenpaw.mobile -a EntryAbility
$HDC shell snapshot_display -f /data/local/tmp/x.jpeg && $HDC file recv /data/local/tmp/x.jpeg /tmp/x.jpeg
```

设备：鸿蒙真机（1316×2832，density≈3.6）

## 鸿蒙文档 MCP（华为开发者知识远程服务）

```bash
# 搜索
curl -sS --max-time 60 --location 'https://connect-api.cloud.huawei.com/api/developerknowledge/mcp' \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -d '{"method":"tools/call","params":{"name":"searchDocuments","arguments":{"SearchDocumentsReq":{"query":"HdsNavigation titleMode"}}},"jsonrpc":"2.0","id":1}'
# 取全文（names ≤10）
#   "params":{"name":"getDocumentsById","arguments":{"GetDocumentsByIdRequest":{"names":["document/cn/harmonyos-guides/..."]}}}
```

## 源码结构

- `entry/src/main/ets/pages/Index.ets` — 壳（HdsNavigation + 4 tab）
- `entry/src/main/ets/components/` — ConnectPanel / AgentsTab / CommunityTab / WorkbenchTab
- `entry/src/main/ets/services/` — RelayClient / RelayCodec / AgentStore / ThemeManager
- 上游参考：`../SC/qwenpaw-pr7378/apps/qwenpaw-mobile/`
