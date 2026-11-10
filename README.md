# deepseek-harness-termux

> 这是一个针对 **Termux 原生环境**的 dsh 最小可用补丁与排雷集合，不是官方方案，也不保证跨版本长期有效。
>
> 本仓库基于 [Vengisk/deepseek-harness-termux](https://github.com/Vengisk/deepseek-harness-termux) 的上游工作继续维护：补丁思路、排错结论与预编译方案均源自该仓库，本仓库在此之上完成 dsh `0.2.2-rc.1` 适配、启动关键补丁（09/10/11）、安装前置校验与文档重构。上游作者的署名保留在 commit 历史中。

`@deepseek-ai/dsh`（DeepSeek Harness，官方仓库 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)）的 npm 包是按 glibc Linux 构建的。在 Android/Termux 上它会以一种很难自己定位的方式启动失败 —— 不是缺依赖，而是缺一个**根本不存在的 android 平台预编译二进制**。

本仓库的做法不是给 dsh 换一个 Linux 环境，而是**把 Android 兼容性问题逐个补掉**：12 个源码补丁 + 本机编译原生模块 + 一个能告诉你"现在到底哪里坏着"的自检脚本。

每个结论都对应可复现的步骤或报错，见 [`troubleshooting.md`](troubleshooting.md)。

English: [`README.en.md`](README.en.md)

---

## 目录

- [快速开始](#快速开始)
- [验证环境（验证边界）](#验证环境验证边界)
- [优势](#优势)
- [局限与风险](#局限与风险)
- [已知隐患](#已知隐患)
- [适用人群](#适用人群)
- [不适用人群 / 不适用场景](#不适用人群--不适用场景)
- [补丁清单](#补丁清单)
- [自检](#自检)
- [路线对比](#路线对比)
- [免责声明](#免责声明)

---

## 快速开始

### 前置条件

```bash
pkg update -y && pkg upgrade -y
pkg install -y nodejs-lts binutils make pkg-config clang python cmake patch git proot which ripgrep
```

`install.sh` 会自动安装缺失的包，但先手动装一遍能让失败更早暴露。

### 方案 A — 本机编译（完整控制）

```bash
git clone https://github.com/y0u41/deepseek-harness-termux.git
cd deepseek-harness-termux
bash install.sh          # 5–15 分钟，本机编译 node-pty / koffi
dsh web
```

### 方案 B — 预编译原生模块（无需编译）

```bash
npm i -g https://github.com/y0u41/deepseek-harness-termux/releases/latest/download/dsh-termux-full.tgz
dsh web
```

详见 [`prebuilt/README.md`](prebuilt/README.md)。

### 打开界面

`dsh web` 会打印一个带 token 的地址，例如：

```
dsh web: http://127.0.0.1:3080/?token=xxxxxxxx
```

> ⚠️ **必须把完整 URL 手动粘贴进浏览器地址栏，或打开后刷新一次。**
> 从其他 App 跳转（`termux-open-url`）打开会因 cookie 的 `SameSite=Strict` 而返回 401。原因与绕过方式见 [`troubleshooting.md` 问题 2](troubleshooting.md#2-浏览器打开后显示-dsh-web-authentication-required-reopen-the-url-printed-by-dsh-web)。

### 安全地启停

不要用 `pkill -f "dsh web"` —— 你自己的 shell 命令行里也含这个字符串，会被一起杀掉（退出码 143）。

```bash
# 用 PID 精确管理，或记录 dsh web 打印的 PID
kill "$(cat ~/.dsh-web.pid 2>/dev/null)"
```

---

## 验证环境（验证边界）

下表是**实际跑通并做过完整自检**的组合。除此之外一律标注为**未验证**。

| 项 | 已验证值 | 说明 |
|---|---|---|
| 设备架构 | `aarch64` | **仅 arm64**。x86_64 未验证，且本仓库的原生产物与 NDK 布局只覆盖 aarch64 |
| Android 版本 | **16**（SDK 36） | 未验证：Android 8–15。docs 声称 8+ 可用，本仓库未实测 |
| Termux 版本 | `0.119.0-beta.3` | 来自 F-Droid。Google Play 版未验证（通常已废弃） |
| Node.js | **v26.13.0**（ABI 147） | 要求 ≥ 24。未验证：Node 20 / 22 / 24 |
| npm | `12.2.2` | |
| pnpm | `12.18.0` | 插件管理需要 |
| clang | `21.1.8` | 编译原生模块需要 |
| ripgrep | `15.2.0`（`+pcre2`） | |
| proot | Termux 包 `proot` | 沙箱运行器 |
| dsh | **`0.2.2-rc.1`** | 补丁针对此版本的上游源码生成，其他版本**未验证** |
| SELinux 上下文 | `u:object_r:app_data_file:s0:c20,c257,c512,c768` | 该上下文下 `link(2)` **被全线拒绝**，见补丁 02 |
| 共享存储 | `/sdcard` 可用（FUSE） | FUSE 语义限制仍在，见[局限与风险](#局限与风险) |

**明确未验证的组合**：

- Node 20 / 22 / 24（`internal/modules/*` 的形状在 24.12 附近有变化，补丁 09 的降级路径依赖 24+）
- Android 8–15、Android 17+
- x86_64 / armeabi-v7a 设备
- 非 Termux 的 Android 终端（如 UserLAnd、Andronix）
- dsh 0.2.2-rc.1 之外的任何版本
- Google Play 版 Termux

---

## 优势

| # | 优势 | 前提条件（不满足则优势不成立） |
|---|---|---|
| 1 | **无中间层，性能最接近原生** —— Node 直接跑在 Android 内核上，没有 rootfs、没有 proot 的 ptrace 翻译 | 原生模块必须本机编译成功。编译失败则无性能可言 |
| 2 | **与 Termux 环境天然互通** —— dsh 里的 shell 就是你的 Termux shell，`pkg` 装的工具、`$PREFIX` 下的程序直接可用，无需 `--bind` 映射 | 你确实想用 Termux 的工具链。若你更想要 apt 生态，这条不构成优势 |
| 3 | **体积最小** —— 不需要额外装一套 rootfs（省 1–2 GB） | 不含你额外装的 `pkg`（clang/cmake/ripgrep 等仍需数百 MB） |
| 4 | **启动最快** —— 无 chroot/proot 初始化开销 | 差异在秒级，日常感知不强；冷启动主要耗时在 Node 自身 |
| 5 | **Android 原生集成可用** —— 补丁 04 让"在 App 中打开"真的能唤起 Android intent（`termux-open`） | 仅在 Termux 环境内有效。proot 里需额外桥接 |
| 6 | **每个补丁都有明确的失败信号** —— 补丁不是"能跑就行"，而是都能用一条命令验证是否仍生效 | 你需要愿意跑 `healthcheck.sh` 并读输出 |
| 7 | **自检脚本能区分"坏"和"已知限制"** —— `healthcheck.sh` 输出 `FAIL` 与 `WARN`，后者是文档化平台约束，不是故障 | `WARN` 需要你理解其含义，否则容易被误当成故障 |

---

## 局限与风险

| # | 局限 / 风险 | 影响 | 缓解方式 |
|---|---|---|---|
| 1 | **沙箱不是安全边界**（proot `enforcement: partial`） | `read-only` 策略**不生效**；沙箱内可见整个宿主文件系统；uid 与宿主相同。无法阻止模型越权读写 `~/.ssh`、`~/.dsh/.credentials.yaml` | 依赖 dsh 自身的审批（approval）机制。需真实隔离请用远程 Linux 主机或独立设备 |
| 2 | **原生模块编译脆弱** | clang / cmake / NDK sysroot / node headers / `common.gypi` 任一环节出错即失败，且报错常不指向真正原因 | `install.sh` 做了两阶段安装（先 `--ignore-scripts`，环境就绪后再编译）；失败时按 [`troubleshooting.md` 3/4](troubleshooting.md) 排查；或用方案 B 预编译 |
| 3 | **dsh 版本漂移** | `npm i -g @deepseek-ai/dsh` 会覆盖全部补丁与 shebang，启动崩溃立即复现；上游重构会让补丁 `patch` 拒绝应用 | 升级后**必须**重跑 `bash install.sh`；关注输出里的 `[SKIP] ... inapplicable`，出现即说明需重新生成补丁 |
| 4 | **`link(2)` 被 SELinux 全线拒绝** | 会话持久化、workspace 归档的原子写入路径失效（`EACCES`/`EPERM`） | 补丁 02 回退到同盘原子 `rename(2)`（已实测可用）。**注意**：workspace 与 `DSH_HOME` 在同一文件系统内才保持原子性 |
| 5 | **`/sdcard` 是 FUSE** | 无硬链接、无 exec 位、无软链接、大小写不敏感、`rename` 语义不同 | 把 `DSH_HOME` 与 workspace 放在内部存储（`$HOME`）。`healthcheck.sh` 第 8 节会实测并在越界时 `FAIL` |
| 6 | **Android 12+ phantom process killer** | 后台 `node` 可能被系统回收，表现为"用着用着突然连不上" | `termux-wake-lock` + 设置里把 Termux 电池优化设为"无限制"。只能降低概率，无法关闭 |
| 7 | **文档预览/转换不可用** | docx / xlsx / pptx / pdf 的预览与格式转换失败（`libreoffice-kit` 缺 `libreoffice`） | 无。Termux 上装 `libreoffice` 基本无解；需要此功能请走 proot Ubuntu |
| 8 | **仅覆盖 aarch64** | x86_64 / armv7 设备无法使用本仓库的原生产物与 NDK 布局 | 无。换 proot Ubuntu（有 linux-arm64-gnu 预编译产物） |
| 9 | **Node 主版本敏感** | Node < 24 未验证；`internal/modules/*` 形状在 24.12 附近有变化，补丁 09 的降级路径依赖 24+ | 用 `pkg install nodejs-lts` 的最新版；升级 Node 大版本后重跑 `install.sh` 重编原生模块 |
| 10 | **安装体积大** | 完整 dsh 约 **750 MB**（含 `@img/sharp-wasm32` 的 WASM 产物）；`~/.dsh` 约 8 MB | 无法显著减小；空间不足的设备建议用方案 B 的分层变体 |
| 11 | **认证 cookie 为 `SameSite=Strict`** | 从外部 App 跳转打开 Web UI 会得到 401 | 手动粘贴 URL 进地址栏，或打开后刷新一次。未做 `SameSite=Lax` 改动（那会削弱 CSRF 防护） |

---

## 已知隐患

这一节只列**目前仍存在、且没有彻底解决**的问题。每条都注明了结局。

### 1. 沙箱隔离缺失 —— 部分缓解，无法根治

`bubblewrap` 需要 `user_namespaces`，Android sepolicy 拒绝。框架按 `proot → bwrap → landlock` 探测，最终选中 `proot` 并标记 `enforcement: "partial"`。

实测（Android 16 / SDK 36 / arm64）：

| 测试项 | 结果 |
|---|---|
| 命令执行（`read-only` / `workspace-write`） | ✅ exit 0 |
| workspace 内写入并回读 | ✅ |
| `/tmp` 重定向到 `$PREFIX/tmp` | ✅ |
| **`read-only` 策略是否强制** | ❌ **不强制**，仍成功写入 |
| **宿主文件系统可见性** | ❌ **完全可见** |
| **用户身份** | ❌ `uid` 与宿主相同 |
| **namespace / seccomp** | ❌ 均无（proot 是 ptrace 用户态重定向） |

**权限保护来自 dsh 自身的审批机制，不是来自这个沙箱。请勿把它当容器。**

### 2. 上游缺 android 预编译二进制 —— 已绕过，未根治

`node-addon-require-builtin` 的 `optionalDependencies` 只有 darwin / linux / win32，**没有 android-arm64**。补丁 09/10 让 dsh 改走 `--expose-internals`，但这意味着**整个 dsh 依赖这个 flag**：

- `install.sh` 改写 `lib/bin.js` 的 shebang 并加 `~/.bashrc` 别名
- 任何绕过 shebang 直接 `node <dsh>/lib/bin.js` 的调用都会重现崩溃
- 升级覆盖补丁后立即崩溃

### 3. 文档转换能力缺失 —— 无法解决

`libreoffice-kit` 需要 `libreoffice` 可执行文件。建议当作该功能不存在。

### 4. 后台存活无法保证 —— 部分缓解

Android 12+ phantom process killer 无法关闭，只能 `termux-wake-lock` + 关闭电池优化。

### 5. 补丁与上游版本的强耦合 —— 结构性代价

补丁用 `diff -u` 针对 `@deepseek-ai/dsh` **0.2.2-rc.1** 的源码上下文生成。上游任何重构都可能使 `patch` 拒绝应用。这不是可以"修好"的问题，是"对上游包打补丁"这种方案的固有代价。

---

## 适用人群

- 愿意折腾，能接受"先读报错再动手"的人
- **需要 dsh 运行在 Termux 原生环境**里的人（要用 `$PREFIX`、`pkg` 生态、现有 Termux 工具链）
- 想理解 Android 上 Node 原生模块、SELinux、FUSE 各自会怎么坏的人
- 能接受"每次升级 dsh 都要重跑一次安装脚本"的人
- 把它当**个人开发/实验工具**，而不是对外提供服务的人

## 不适用人群 / 不适用场景

明确写出来，避免误用：

| 你的需求 | 为什么这套方案不合适 | 建议替代 |
|---|---|---|
| **生产级稳定** | dsh 本身是 `0.2.2-rc.1`（RC 版本），本仓库是社区补丁集，两者都不承诺稳定 | 远程 Linux 主机 + 官方 dsh |
| **完整沙箱 / 真实隔离** | 这里的沙箱是 proot，`read-only` 不生效、宿主 FS 可见、uid 不变 | 独立设备、Android 工作资料、远程 Linux |
| **不能接受调试成本** | 编译工具链、bionic/glibc 差异、SELinux、FUSE 都可能要自己分辨 | proot Ubuntu 或封装 APK |
| **需要系统级包管理** | Termux 是 `pkg`，包集合与 apt 不同；复杂依赖（如 `libreoffice`）基本无解 | proot Ubuntu |
| **需要文档预览/转换** | 缺 `libreoffice` | proot Ubuntu（`apt install libreoffice`） |
| **不想碰编译** | 方案 A 需要 clang / cmake / NDK sysroot | 方案 B 预编译包，或 proot Ubuntu |
| **设备非 arm64** | 原生产物与 NDK 布局只覆盖 aarch64 | proot Ubuntu |
| **Node < 24** | 未验证，`internal/modules/*` 形状不同 | 升级 Node，或 proot Ubuntu |
| **给不懂技术的人用** | 需要能读终端报错 | 封装 APK |

---

## 补丁清单

| 补丁 | 目标包 | 修复内容 |
|---|---|---|
| [`01-terminal-bash-android-shell.patch`](patches/01-terminal-bash-android-shell.patch) | `dsh-terminal-bash` | 解析真实存在的 shell（Android 没有 `/bin/bash`） |
| [`02-session-persistence-link-rename.patch`](patches/02-session-persistence-link-rename.patch) | `dsh-session-persistence-jsonl` | `link(2)` 被 SELinux 拒绝（`EACCES`/`EPERM`）时回退同盘原子 `rename(2)` |
| [`03-subprocess-local-android.patch`](patches/03-subprocess-local-android.patch) | `dsh-subprocess-local` | 进程组检查（`kill(-pid, 0)`）把 `android` 视同 `linux` |
| [`04-native-command-termux-open.patch`](patches/04-native-command-termux-open.patch) | `dsh-native-command` | Android 下用 `termux-open` 打开路径/URL；启用原生路径检测 |
| [`05-host-directory-picker-native-android.patch`](patches/05-host-directory-picker-native-android.patch) | `dsh-host-directory-picker-native` | Android 下目录选择走 Linux（zenity）路径 |
| [`06-workspace-archive-skip-session-known-check.patch`](patches/06-workspace-archive-skip-session-known-check.patch) | `dsh-workspace` | 归档时跳过 `sessionKnown()` 校验（全新安装下会失败） |
| [`07-sandbox-local-proot-runner.patch`](patches/07-sandbox-local-proot-runner.patch) | `dsh-sandbox-local` | Android 平台链加入 `proot`，`enforcement: partial`；`/tmp` 重定向到 `$PREFIX/tmp` |
| [`08-dsh-tool-fs-search-android-rg.patch`](patches/08-dsh-tool-fs-search-android-rg.patch) | `dsh-tool-fs-search` | `require.resolve()` + 系统 rg 回退；`@vscode/ripgrep` 无 android-arm64 平台包（见 [`docs/termux-ripgrep-fix.md`](docs/termux-ripgrep-fix.md)） |
| [`09-app-boot-expose-internals.patch`](patches/09-app-boot-expose-internals.patch) | `dsh-app-boot` | `internalModules()` 先走 `--expose-internals`，再回退原生 addon |
| [`10-inspector-worker-expose-internals.patch`](patches/10-inspector-worker-expose-internals.patch) | `dsh-experimental-inspector` | worker 的 `execArgv` 由 `[]` 改为 `["--expose-internals"]`（worker 不继承父进程 flag） |
| [`11-node-addon-system-flock-android.patch`](patches/11-node-addon-system-flock-android.patch) | `node-addon-system` | `flock.js` 放行 `android` 平台；配合 install.sh 5d 编译 android-arm64 `system.node`，会话写锁不再报 `ERR_FLOCK_UNSUPPORTED_PLATFORM` |
| [`koffi-statx.patch`](patches/koffi-statx.patch) | `koffi` | 条件编译掉 bionic 中不存在的 `statx()` |

补丁 09/10 是最容易失效也最容易"莫名其妙又能跑了"的两个，单独说明见 [`troubleshooting.md` 问题 1](troubleshooting.md#1-dsh-web-启动即崩溃no-usable-native-binding-found-for-node-addon-require-builtin-android-arm64)。

---

## 自检

```bash
bash healthcheck.sh            # 人类可读报告
bash healthcheck.sh --quiet    # 只返回退出码（0 = 无 FAIL）
bash healthcheck.sh --verbose  # 附额外细节
```

覆盖范围：

1. 平台 / 工具链（Android、`$PREFIX`、Node 版本与 ABI、dsh 版本、磁盘）
2. **`--expose-internals` 可达性**（shebang、`internal/modules/*`、原生 addon 是否被意外启用）
3. 原生模块（`node-pty`、`koffi`、`sharp` 真实编解码、PTY 真实 spawn）
4. 搜索后端（rg、`@vscode/ripgrep-android-arm64` shim）
5. 补丁覆盖（逐个 `patch --dry-run --reverse` 验证）
6. 沙箱能力（proot 可执行性 + 明确的 partial 说明）
7. 端口占用（connect 探测 + 未认证请求应返回 401）
8. **`/sdcard` 与 FUSE 风险**（实测 `link(2)` / `rename(2)`，并检查 `DSH_HOME` 是否落在共享存储）
9. 凭据（是否存在及权限是否 600）
10. 后台存活（SDK 版本与 `termux-wake-lock`）

`WARN` 是文档化的平台限制，不是故障；`FAIL` 才是需要处理的问题。

---

## 路线对比

Termux 原生 / proot Ubuntu / 封装 APK 三条路的详细对比（性能、体积、沙箱、维护成本、以及本仓库 11 个问题在三条路上各自的表现）见 [`docs/comparison.md`](docs/comparison.md)。

---

## 项目结构

```
deepseek-harness-termux/
├── README.md                  # 本文件（中文主文档）
├── README.en.md               # English
├── troubleshooting.md         # 排错手册（现象 → 原因 → 方案 → 是否彻底解决）
├── healthcheck.sh             # 安装后自检
├── install.sh                 # 安装脚本（幂等，含环境校验）
├── LICENSE                    # MIT
├── docs/
│   ├── comparison.md          # 三条路线对比
│   └── termux-ripgrep-fix.md  # ripgrep 修复细节
├── patches/                   # 12 个源码补丁（在各包目录内 patch -p1）
├── prebuilt/                  # 方案 B：预编译部署包
└── scripts/                   # 维护者脚本（构建预编译包等）
```

---

## 免责声明

1. **非官方**。本项目由社区维护，与 DeepSeek AI 及 `deepseek-harness` 官方无关，不受其支持或背书。
2. **无稳定性承诺**。`@deepseek-ai/dsh` 当前为 `0.2.2-rc.1`（RC 版本）。本仓库的补丁针对该版本源码生成，**不保证跨版本有效**。
3. **无安全承诺**。本文档已明确说明：proot 沙箱**不是安全边界**，`read-only` 策略不生效、宿主文件系统可见、进程身份无隔离。**不要在存放敏感凭据的设备上让它执行不可信命令。**
4. **使用风险自负**。安装脚本会修改全局 npm 包（`$(npm root -g)/@deepseek-ai/dsh` 下的源码）与 `~/.bashrc`。`~/.bashrc` 只追加不改写。请在了解后果的前提下运行。
5. **不提供担保**。按 MIT 许可，「软件按原样提供」，不附带任何明示或暗示的担保。
6. **数据责任**。本仓库建议把工作数据放在内部存储（`$HOME`），请勿把 `DSH_HOME` 或 workspace 放在 `/sdcard`（FUSE 语义会导致数据损坏）。

---

## 致谢

- **[DeepSeek AI](https://github.com/deepseek-ai)** —— [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 框架
- **[@mexiaosqwq](https://github.com/mexiaosqwq)** —— [dsh-web-mobile](https://github.com/mexiaosqwq/dsh-web-mobile) 移动端 UI 适配插件
- **Termux 社区** —— Android 终端环境
- **koffi / node-pty / sharp** 的维护者

## 许可证

MIT —— 与上游 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 相同。见 [LICENSE](LICENSE)。
