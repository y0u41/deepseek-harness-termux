# Changelog

本项目的版本号沿用 `<dsh 版本>-termux.<补丁发布号>`。
补丁发布号递增表示"同一上游 dsh 版本上的仓库更新"；上游在同一 minor 内推进 RC（rc.3 → rc.5）
时前缀 `0.2.2` 不变，只递增发布号。升级方式见 README 的「升级与卸载」。

## v0.2.2-termux.4 — 2026-11-20

上游适配版本从 `0.2.2-rc.3` 升级到 `0.2.2-rc.5`（npm 的 `latest` 与 `next` tag 现在都指向 rc.5）。
**本轮没有任何补丁需要重新生成**：12 个补丁在 rc.5 上全部 `-F0` 干净应用，并逐条做了运行时验证。

### 为什么补丁不用改（逐条核对，不是“试了一下没报错”）

- 对比 rc.3 与 rc.5 的 12 个目标包源码，唯一有代码变更的是
  `@deepseek-ai/dsh-session-persistence-jsonl/lib/worker.cjs`（新增 `CONTENT_REFUSED` 错误码）。
  补丁 02 改的是同包的 `lib/index.js`，不在变更区，所以 `-F0` 依旧精确命中。
- `@deepseek-ai/dsh/lib/*`（补丁 04 依赖的内联副本、09/10 依赖的 bundle）逐字节未变；
  `dsh-subprocess-local/lib/runner-launch-CKTiL8M8.js` 的文件名与内容都没变，
  所以补丁 03 **不需要**跟着构建哈希改名（termux.3 时正是它改名导致重生成）。
- 其余 9 个目标包，以及 `koffi@3.1.1`、`@deepseek-ai/node-addon-system@0.1.2` 均未变。

### 运行时验证（真机：Android 16 / SDK 36 / aarch64，Node 26.13.1）

- `bash install.sh` 全绿：12/12 补丁 `[APPLIED]`，node-pty / koffi / flock / ripgrep shim 全部 OK，
  `dsh --version` 为 `0.2.2-rc.5`
- `bash healthcheck.sh`：**40 passed / 6 warnings / 0 failures**（6 条 warning 均为文档化的平台限制）
- 行为级抽查，不只看“补丁打过”：
  - 04：`canOpenNativePath({platform:"android"}) === true`
  - 08：`resolveRgPath()` → `$PREFIX/bin/rg`（文件存在）
  - 03：`platform === "android"` 走 `LinuxProcessInspector` 分支
  - 01：`defaultBashShell()` 解析到 `$PREFIX/bin/bash`
- `dsh web` 实际启动成功（打印 token URL；HTTP 401 是未带 token 的预期结果）

### 修复：install.sh 把 Termux 已不存在的 `python3` 当作包名（阻断级）

- 当前 Termux 的 Python 3 包名是 **`python`**，`python3` 只是可执行文件符号链接，仓库里没有名为 `python3` 的包
- 原 step 0 用 `dpkg -s python3` 判断，永远 MISS → 触发 `pkg install python3` → 必失败 → **整个安装在第一步中止**（本轮实机复现）
- 改为 `python`（`SYSTEM_PKGS` 与 step 0 后的 `TOOLS` 两处），并注明原因；
  `PYTHON=` 发现逻辑仍优先 `python3`，node-gyp 侧不受影响

### 已知问题与文档：profile 插件版本漂移

- dsh 0.2.2 起对 `~/.dsh/profiles/*` 里安装的插件做 exact-version 校验。dsh 升到 rc.5 后，
  锁在 rc.3 的 `@deepseek-ai/dsh-tool-subagent` 会被禁用，日志出现
  `disabling profile plugin row ... incompatible with dsh 0.2.2-rc.5`，subagent 相关行随之消失
- 处理方式写进 `troubleshooting.md` 第 17 节，README「升级与卸载」加了提醒
- 本机已按该流程把 `~/.dsh/profiles/web` 的 `@deepseek-ai/dsh-subagent-codex` 由 rc.3 升到 rc.5
  （`pnpm install` 后传递依赖 `dsh-tool-subagent` 同样为 rc.5），重启 `dsh web` 后不再有禁用日志

### healthcheck 新增第 11 节：profile 插件版本检查

- 扫描 `~/.dsh/profiles/*/package.json` 里形如 `0.2.2-rc.N` 的 `@deepseek-ai/dsh-*` 依赖，
  以及已解析的 `node_modules/@deepseek-ai/dsh-tool-subagent/package.json`，与当前 dsh 版本对比
- 不匹配时 WARN 并给出修复提示（升依赖 + `pnpm install`，指向 troubleshooting 第 17 节）
- 不引入 FAIL：升级 dsh 而插件暂无新版本时，这是可接受的降级

### 版本同步

- `install.sh` / `prebuilt/install.js` / `patches/targets.json` / `.github/workflows/ci.yml`
  的 pin 统一为 `0.2.2-rc.5`；`DSH_VERSION=<ver>` 仍可覆盖
- `prebuilt/package.json`：`0.2.2-termux.3` → `0.2.2-termux.4`，issue 模板里的示例版本同步
- 上游行为变更（与补丁无关，仅记录，便于用户对比升级前后）：
  - rc.3 起 DeepSeek 流式内容拒答的错误码 `MALFORMED_RESPONSE` → `CONTENT_REFUSED`
  - rc.4 起交付组合不再固定搜索提供方，DeepSeek 模型的会话中网页搜索回落到旧版 Messages 搜索
    （rc.5 没有新的 upgrade-guide 条目，即无破坏性接口变更）

## v0.2.2-termux.3 — 2026-11-14

上游适配版本从 `0.2.2-rc.1`（npm `latest` tag）升级到 `0.2.2-rc.3`（npm `next` tag）。
全部 11 个源码补丁按 rc.3 的 bundle 重新生成，`patch -F0` 逐条验证可干净应用。

### 重新生成：补丁 03（subprocess-local）

- 目标文件随上游构建哈希改名：`lib/runner-launch-B2zsQ1Dz.js` → `lib/runner-launch-CKTiL8M8.js`
- `fallbackOwner().alive()` 的判断结构被上游重写（不再是一行三元嵌套），补丁改为在
  `directSettled && platform === "linux"` 分支上追加 `android`
- 语义不变：`createProcessInspector()` 与进程组存活判定仍把 `android` 视作 `linux`

### 重新生成：补丁 08（ripgrep）

- rc.3 把 `resolveRgPath()` 从 `dsh-tool-fs-search` 抽到了新包 **`@deepseek-ai/dsh-util-ripgrep`**，
  工具包只保留 `import { resolveRgPath, spawnRipgrep }`，因此补丁目标包随之改变
- 补丁内容保持原有策略：`require.resolve()` 静默解析 `@vscode/ripgrep-<platform>-<arch>`，
  失败回退 `RIPGREP_BIN` / `$PREFIX/bin/rg` / `/usr/bin/rg` / `/usr/local/bin/rg`，
  并保留 Electron 的 `.asar` → `.asar.unpacked` 重写
- 同步更新：`patches/targets.json`、`install.sh`（应用表 + 校验表）、`healthcheck.sh`、
  `prebuilt/install.js`、`scripts/fix-dsh-glob-rg.sh`

### 其余补丁

- 01/02/04/05/06/07/09/10/11 的修改内容未变，仅按 rc.3 的实际行号/上下文重新生成
- `koffi-statx.patch`（koffi 3.1.1）与补丁 11（node-addon-system 0.1.2）的上游版本未变

### 版本同步

- `install.sh` / `prebuilt/install.js` / `patches/targets.json` / `.github/workflows/ci.yml`
  的 pin 统一为 `0.2.2-rc.3`；`DSH_VERSION=<ver>` 仍可覆盖
- `prebuilt/package.json` 版本跟随本仓库发布号：`0.2.2-termux.2` → `0.2.2-termux.3`

### 修复：healthcheck 把“上游已折叠”误报为未应用

- 上游把补丁的同一改动自行合入时（重命名内容哈希 bundle、或把逻辑搬到新包），
  `patch --reverse --dry-run` 会失败，原来会直接报 `NOT applied — re-run install.sh`
- 新增 `patch_upstreamed()`：按**行为**而非 diff 形状探测，命中时输出
  `obsolete — upstream already ships this change`，不再误报
- 03 同时要求 `lib/index.js` 与 `runner-launch-*.js` 都命中，避免“半应用”被当成 obsolete；
  08 探测 `dsh-util-ripgrep/lib/index.js` 中的 `RIPGREP_BIN` 回退
- 注意：`install.sh` 的打补丁环节仍是“不适用即失败”（关键补丁直接中止），未同步该豁免

## v0.2.2-termux.2 — 2026-11-10

针对 `v0.2.2-termux.1` 审查结果的一次交付质量修复。核心结论是：**两条安装路径此前都不可用**，
而且都以"成功"的退出码结束。

### 修复：方案 B 在 npm 12 上装出空包（阻断）

- `prebuilt/package.json` 新增 `dsh-termux-setup` bin；`prebuilt/bin/setup.js` 作为显式入口
- `prebuilt/bin/dsh` 在发现部署缺失时自动补跑一次安装，而不是报 `Cannot find module`
- 文档全部改为 `npm i -g <tgz> && dsh-termux-setup`，并解释 npm 12 的 `allowScripts` 行为
- 原因：npm 12 默认不执行依赖的 `postinstall` 且退出码仍为 0，而原方案的全部逻辑都在 `postinstall` 里

### 修复：安装顺序导致 shim 被 npm 删除（阻断）

- `install.sh`：`@img/sharp-wasm32` 的安装从 step 6 前移到 step 4（任何 shim 创建之前），
  并加 `--no-save --package-lock=false --ignore-scripts`（不再污染 `dsh/package.json`）
- `prebuilt/install.js`：同样的顺序修正（先所有 npm 安装，再落 native/shim，最后统一验证）
- 验证步骤移到 shim 写入之后，新增 ripgrep shim 的存在性检查
- 原因：`npm install` 在 dsh 目录内会 `reify()`，把不在依赖树里的顶层包（手工 shim）当 extraneous 删除

### 修复：补丁 04 是死代码（阻断）

- 补丁 04 现在同时修改真正的入口 `lib/index.js`（bundle 内联副本）与 `lib/types/path-opener.js`
- 运行时验证：`canOpenNativePath({platform:'android'}) === true`，`openNativePath` 走 `termux-open`
- 此前 `healthcheck.sh` 用 `patch --reverse --dry-run` 判定"已应用"，对死代码同样返回成功（假阳性）

### 修复：装 `@latest` + 补丁失败不致命（阻断）

- `install.sh` 固定安装 `0.2.2-rc.1`（`DSH_VERSION` 可覆盖），不再 `@latest`
- `apply_patch` 改为三态返回（新应用 / 已应用 / 不适用），不再把"不适用"混进 `[SKIP]`
- 02 / 09 / 11 / koffi-statx 失败**直接中止**安装
- 新增 `--force-reinstall`（从旧版本升级时重新解包 dsh，否则旧补丁会让新旧补丁都不匹配）
- 新增交付前最后一道门：`dsh --version` 成功才打印 "Installation complete!"

### 修复：`pkg install nodejs` 会卸掉 `nodejs-lts`（高危）

- 从 `SYSTEM_PKGS` 移除 `nodejs`，仅在缺少 node 时安装 `nodejs-lts`
- 修复 `pkg install -y awk` 的无效包名（Termux 只有 `gawk`）
- preflight 不再要求尚未安装的工具（干净设备原来必然失败）

### 修复：npm 看门狗留下孤儿进程（高危）

- 去掉 `{ npm ...; } &` 的命令组，`$!` 现在就是 npm 的 PID
- 超时同时 `pkill -TERM/-KILL -P` 清理 npm 的子进程

### 修复：补丁漂移被 fuzz 掩盖（高危）

- 全部 12 个补丁重新生成，`patch -F0` 下 **12/12 精确命中**（此前补丁 05 需要 fuzz 2 + offset 41 行）
- 补丁 01 改用 `$PREFIX/bin/bash`（不再硬编码 Termux 路径），去掉会传错参数的 mksh 回退
- 补丁 02 的 `rename` 回退补回 `link(2)` 的 create-only 语义（先 `lstat` 再 rename，避免静默覆盖）
- 补丁 03 补上 `dsh-subprocess-local/lib/index.js` 中另一处 `platform === "linux"`
- 补丁 05 重新生成并如实描述：Termux 上 zenity/kdialog 都不存在，目录选择实际仍不可用
- 补丁 06 的作用域收窄到 android（不再影响其他平台的 `sessionKnown` 校验）
- 补丁 08 支持 `$PREFIX`、`RIPGREP_BIN` 无效时回退、保留 Electron `.asar` 处理
- 补丁 09 的 `requireInternal` 不再吞掉错误返回 `undefined`（那会把启动失败变成
  `TypeError: Cannot read properties of undefined`），改为抛出带 `cause` 的明确错误

### 修复：Node 门槛四处矛盾（高危）

- 统一为 `>= 24.9.0`（`@deepseek-ai/dsh` 自身的 `engines`）
- 涉及 `install.sh`、`prebuilt/install.js`、`prebuilt/package.json`、
  `prebuilt/README*.md`、`healthcheck.sh`、`README*.md`

### 改进：healthcheck

- 新增端到端 `dsh --version` 与 `$PREFIX/bin/dsh` 链接检查
- 检测"装了 dsh-termux 但没跑 setup"的情形，并给出 `dsh-termux-setup` 提示
- 探针文件改用 `mktemp -d` + `trap` 清理（不再在 `$HOME` 留 `.dsh-flock-healthcheck`）
- 支持 `NO_COLOR` 与非 TTY 输出；修复 `--help` 多打一行 `set -uo pipefail`
- Node 版本不达标从 `WARN` 改为 `FAIL`；环境不适用时返回退出码 2

### 新增

- `scripts/uninstall.sh`（支持 `--dry-run` / `--purge`）
- `.github/workflows/ci.yml`：shellcheck、`bash -n`、`node --check`、版本一致性、
  **补丁对 pin 版本原始包的 `-F0` 适用性检查**（每周定时跑，上游发新版会先红）
- `patches/targets.json`：补丁 → 目标包 + 严重级别的单一来源；CI 强制每个补丁都登记
- `.github/ISSUE_TEMPLATE/bug_report.yml`
- README「升级与卸载」章节

### 文档订正

- proot 沙箱：说明 `-b /:/` 是**全盘读写**绑定，`read-only` 不生效、uid 不变、无 namespace
- `/tmp` 重定向：仅在 `workspace-write` 模式生效，且依赖 `$PREFIX/tmp` 已存在（不再是简单的 ✅）
- 补丁 10：它只影响可选的 inspector 包，不是 `dsh web` 的启动前提；
  修正"worker 不继承父进程 flag"的错误说法（Worker 默认继承，是上游显式写了 `execArgv: []`）
- 问题计数 11 → 16；补丁清单里 05 的实际效果
- README.en.md 补上与中文版对等的方案 B 说明

---

## v0.2.2-termux.1 — 2026-11-10

首个发布：12 个源码补丁、本机编译原生模块、预编译部署包（layered / full）、
`healthcheck.sh`、中英双语文档。
