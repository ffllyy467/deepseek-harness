# dsh web 部署运维手册（本机）

> 本机部署：`notebook-inspire-sj.sii.edu.cn` 代理（path-prefix）后的 dsh web。
> **服务器启动/重启失败时，按本手册定位根因**——以下所有路径在服务器未启动时均可直接读取。
> 会话数据在 `.dsh/sessions/`（JSONL，磁盘持久），崩溃/重启不丢对话。

## 0. 一键诊断（重启失败时最先做）

```sh
pgrep -af 'apps/cli/src/bin.ts'                      # 进程在不在
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3080/   # 端口响应
tail -60 ~/.dsh/logs/dsh_web.log                     # 日志（= 仓库 .dsh/logs/dsh_web.log）
bash deploy/start.sh                                 # 重启（已改进：失败立即报错 + 打印日志尾部）
```

## 1. 已知启动失败模式 → 根因映射

| 日志特征 | 根因 | 处置 |
|---|---|---|
| `cannot get property "webRuntime" without inject` + `loader fibers failed` | profile patch 的 `!!js ctx.webRuntime...` 用在了**未 inject webRuntime 的行**上（ssh/aionui 曾踩坑） | 改成**字面量数组**，或给该行加对应 inject；现网形态见 `.dsh/profiles/web/cordis.patch.yml` |
| `[ui-skin-center] route registration failed: duplicate exact route "/api/skin-center/state"` | skin-center 被**挂载两次**（市场热挂载 or 重复行） | 检查 bundles 列表无重复；`.dsh-market/` 无新增 `hot-*.yml` |
| `FATAL ERROR ... heap out of memory`（exit 134） | 内存泄漏。**历史根因**：剥离 `dsh.bundle` → dshmarket 把家族包当 client-only 自动热挂载（`hot-*.yml` + `MarketHotTree` 累积）→ 100% CPU + OOM | 查 RSS 增长 + `.dsh-market/hot-*.yml` 数量；inspector 定位见 §4 |
| `[ELIFECYCLE] Command failed` 无详情 | pnpm 包装层，详情在日志上方 | 向上翻日志找 `Error:` 正文 |

## 2. 当前部署状态（2026-08-15）

- 代理：`notebook-inspire-sj.sii.edu.cn`（`DSH_TRUSTED_HOSTS`）；workspace 默认 `/inspire/sj-ssd3/project/robot-action/fanluoyi-p-fanluoyi`
- profile patch（`.dsh/profiles/web/cordis.patch.yml`）四行 trustedHosts：
  - `web-runtime` 行：`!!js ctx.webStartup.trustedHosts.concat([...])`——**webStartup 在该行 inject 里，合法**；统一喂给所有读 webRuntime 的围栏（官方 /api、ssh、aionui、better-sidebar）
  - `connection` 行：`!!js ctx.webRuntime.trustedHosts.concat([...])`（webRuntime 在 inject，合法）
  - `ssh` / `ui-dsh-aionui-panel` 行：**字面量数组** `['notebook-inspire-sj.sii.edu.cn']`（它们的行未 inject webRuntime，`!!js` 会失败）
- 已安装插件（**全部 link: 手动方式**，见 §6 红线）：
  - `dshmarket` → `plugins/dsh-market`
  - `@linxin666/dsh-web-ui-all`（聚合）+ 12 子包 → `plugins/dsh-web-ui`
  - `dsh-better-sidebar` → `plugins/dsh-better-sidebar`
- 家族 22 个包的 `dsh.bundle` **已恢复**——**勿再剥离**（剥离 → 市场热挂载循环 → OOM）
- better-sidebar 与 aionui 右侧视觉重叠：aionui 已在 profile patch 禁用（`ui-dsh-aionui-panel` + `disabled: true`），需要时删除该行恢复
- 自定义预设（`~/.dsh/.agent-presets/`，无需重启即出现在新建会话预设选择器）：
  - `liangshen`（梁神模式，两阶段锚定）
  - `we-need-standard` / `we-need-minimal`（复刻内置 standard/minimal 全配置，仅 persona 末尾追加 "We need" 首回复指令）

## 3. 已应用的第三方修复（在 plugins/ 的 clone 内，`git pull` 会丢失，需重打）

- 三个插件共用修复：
  - 客户端硬编码根路径（`/sidebar/*`、`/api/*`、`/dsh-market/*` 等）→ `apiBase()` 前缀（`location.pathname` 目录）
  - host 围栏 `trustedHosts` 扩展（socket 仍须回环；Host 允许回环字面量或信任列表）
- dsh-web-ui 家族额外：Explorer 失败态修复（区分加载中/失败+重试）、`workspace:*` → `link:`、`dsh.bundle` 恢复
- dshmarket 额外：client.js 根路径修复（其 client 在 `client/client.js`，非 `lib/`）
- 重建命令：
  - `plugins/dsh-market`：`pnpm install --store-dir /tmp/pnpm-store && pnpm run build`
  - `plugins/dsh-web-ui`：`pnpm install --store-dir /tmp/pnpm-store && pnpm -r build`
  - `plugins/dsh-better-sidebar`：`pnpm install --store-dir /tmp/pnpm-store && pnpm run build`

## 4. 内存泄漏定位 playbook（inspector）

```sh
kill -USR1 <pid>            # 启用 inspector（node 默认 9229 端口）
# 用 CDP WebSocket（node 自带 WebSocket）连 ws://127.0.0.1:9229/json 里的 URL：
#   Runtime.evaluate  process._getActiveHandles() 计数 FSWatcher/Socket（泄漏迹象）
#   Runtime.evaluate  process.memoryUsage() / getHeapStatistics()（heapUsed vs 限制）
#   HeapProfiler.startSampling + stopSampling（top 分配点）
#   v8.writeHeapSnapshot('/tmp/...') 写快照（写进服务器自己的 /tmp，沙箱不可见；
#     用 Runtime.evaluate fs.copyFileSync 搬到 .dsh/logs 再解析）
# 关键指标：VmRSS 增速（/proc/<pid>/status）、FSWatcher 数量、.dsh-market/hot-*.yml 数量
```

## 5. 红线（违反会导致启动失败/重复挂载）

1. **禁止对家族/better-sidebar 跑 `dsh plugin add/remove/update`**——reconcile 会把 22 个声明了 `dsh.bundle` 的家族子包全部加进 bundles，与聚合包行重复挂载 → 启动失败。安装/卸载一律手动改 `.dsh/profiles/web/package.json`（dependencies + bundles）+ `pnpm install`（需 full 权限，pnpm store 在 /root）。
2. **禁止剥离 `dsh.bundle`**（OOM 根因，见 §1）。
3. profile patch 的 `!!js` **只用在 inject 已声明的服务上**；否则 loader 报 `cannot get property ... without inject`。
4. pnpm 相关命令在 sandbox 内需 `--store-dir /tmp/pnpm-store` 或 full 权限（store 在 /root，沙箱只读）。
