# 三条路线对比：Termux 原生 / proot Ubuntu / 封装 APK

本文回答一个问题：**在 Android 上跑 dsh，应该选哪条路？**

先说结论，再讲依据。

| 你的处境 | 建议 |
|---|---|
| 愿意折腾，需要 dsh 与 Termux 环境（`$PREFIX`、`pkg`、现有工具链）直接互通 | **Termux 原生**（本仓库） |
| 需要稳定的完整 Linux 环境、完整沙箱、能用 apt 装包 | **proot Ubuntu** |
| 只是想给不懂技术的人一个「装了就用的 App」 | **封装 APK** |
| 需要生产级可靠 / 真实安全隔离 | **都不是** —— 用远程 Linux 主机或独立设备 |

---

## 总览

| 维度 | Termux 原生 | proot Ubuntu | 封装 APK |
|---|---|---|---|
| 本质 | 直接在 Android/bionic 上跑 Node | 在 proot 里跑完整 Ubuntu/glibc，再跑 Node | Termux + 预置环境打包成 APK |
| 安装体积 | ~750 MB（dsh）+ Termux 本身 | 1.5–3 GB（rootfs + Node + dsh） | 1–2 GB（含 rootfs 或 Termux 底包） |
| 首次安装耗时 | 5–15 分钟（本机编译原生模块） | 10–30 分钟（下载 rootfs + 安装） | 下载即用（几分钟） |
| 原生模块 | **需本机编译**（node-pty / koffi） | 可用 Linux 预编译包，但需 ABI 匹配 | 预置好，不需编译 |
| 性能开销 | **最低**（无中间层） | 中（ptrace 系统调用翻译，2–5× syscall 开销） | 与所选内核相同 |
| 与 Android 共享存储 | `/sdcard` 有 FUSE 限制 | 同左（需显式 `--bind`） | 同左 |
| 能否 `pkg` / `apt` | `pkg`（Termux 仓库） | `apt`（Ubuntu 仓库，包更全） | 取决于封装方式 |
| 沙箱能力 | ⚠️ proot，`partial`，非安全边界 | ⚠️ 同上（proot 是它自己的运行方式） | 取决于封装 |
| 调试成本 | **高**（bionic/glibc 差异、SELinux、sepolicy） | 中（Linux 语义标准，报错更"正常"） | 低（对使用者）/ **极高**（对封装者） |
| 升级 dsh | 需重跑补丁脚本，注意版本漂移 | 与普通 Linux 一致，风险低 | 需重新打包发布 |
| 受 phantom killer 影响 | 是 | 是 | 是（取决于前台服务实现） |

---

## 1. Termux 原生（本仓库）

### 它是怎么工作的

不给 dsh 换环境，而是**把 dsh 的 Android 兼容性问题逐个补掉**：

- `process.platform` 在 Termux 是 `"android"`，上游 `=== "linux"` 的分支要扩展
- Android 没有 `/bin/bash`，要改 shell 解析（补丁 01）
- SELinux 拒绝 `link(2)`，要回退 `rename(2)`（补丁 02）
- 缺 `node-addon-require-builtin` 的 android 产物，要走 `--expose-internals`（补丁 09/10）
- `bubblewrap` 不可用，沙箱改选 `proot`（补丁 07）
- 没有 `@vscode/ripgrep-android-arm64`，要回退系统 rg（补丁 08）
- `koffi` 调用了 bionic 里不存在的 `statx()`，要编译掉（`koffi-statx.patch`）

然后本机编译 `node-pty` / `koffi`，装上 `@img/sharp-wasm32` 作为图片处理的 WASM 后端。

### 优势

1. **性能最好** —— 没有 rootfs、没有 ptrace 翻译层，Node 直接跑在 Android 内核上
2. **与 Termux 环境天然互通** —— dsh 里的 shell 就是你的 Termux shell，`pkg` 装的工具、`$PREFIX` 里的东西直接可用，不需要 `--bind` 映射
3. **体积最小** —— 不用再装一套 rootfs
4. **启动最快** —— 无 chroot/proot 初始化开销
5. **android-arm64 上 `termux-open` 原生可用** —— 补丁 04 让 dsh 的"在 App 中打开"按钮真的能唤起 Android intent

每条优势的前提：

| 优势 | 前提条件 |
|---|---|
| 性能最好 | 只有本机编译成功才有意义；编译失败就没得比 |
| 环境互通 | 你确实想用 Termux 的工具链。若你更想用 apt 生态，这条不算优势 |
| 体积最小 | 不含你额外的 `pkg` 包；`ripgrep`、`clang`、`cmake` 等仍需装 |
| 启动最快 | 差异在秒级，日常感知不强 |
| `termux-open` | 仅在 Termux 环境内有效；proot 里需要额外桥接 |

### 代价

- **原生模块编译脆弱**。clang/cmake/NDK sysroot/node headers/`common.gypi` 任意一环出问题就失败，且报错信息通常不指向真正原因
- **必须对上游打补丁**。每个 dsh 版本都要验证补丁仍能应用；上游重构就失效
- **调试需要懂 bionic 与 SELinux**。`EACCES` 可能是文件权限、可能是 sepolicy、也可能是 FUSE，得会分辨
- **沙箱很弱**。proot 只是包装层

---

## 2. proot Ubuntu

### 它是怎么工作的

用 `proot-distro install ubuntu` 装一个完整 Ubuntu rootfs，在 proot 里跑 `apt install nodejs`，然后按普通 Linux 方式装 dsh —— 不需要任何本仓库的补丁。

### 优势

1. **报错"正常"**。glibc、标准 Linux 语义、`/proc`、`/sys` 都是常规形态，搜索到的问题通常直接适用
2. **包管理更全**。需要 `libreoffice` 做文档预览？`apt install libreoffice` 真的能装（代价是几个 GB）
3. **dsh 升级无痛**。`npm i -g @deepseek-ai/dsh` 就行，没有补丁漂移问题
4. **`node-addon-require-builtin` 有 linux-arm64-gnu 预编译产物** —— 本仓库最核心的崩溃（问题 1）在这条路上**根本不存在**
5. **环境可整体备份/迁移**。rootfs 就是一个目录

前提条件：

| 优势 | 前提条件 |
|---|---|
| 报错正常 | 你得看得懂 Linux 常规排错；Android 侧的限制依然存在（见下） |
| 包管理更全 | 能接受 1.5–3 GB 体积和 apt 的依赖膨胀 |
| 升级无痛 | 不介意 iOS/Android 上 proot 的性能税 |
| 有 linux 预编译产物 | 需要 arm64-gnu（不是 musl）。选 rootfs 时注意 |
| 可迁移 | 备份/恢复需要用户能找到 `proot-distro` 的 rootfs 路径 |

### 代价

- **性能税**。proot 用 ptrace 拦截并翻译系统调用，I/O 密集场景（`npm install`、ripgrep 全盘搜索）明显变慢
- **体积大**。rootfs + Node + dsh 轻松超过 2 GB
- **和 Termux 环境割裂**。`/sdcard` 要显式 `--bind`；`termux-open`、`termux-wake-lock`、`termux-setup-storage` 都要额外桥接
- **proot 同样是"假隔离"**。你在 rootfs 里，但它不是 namespace；一份文件系统视图不等于安全边界
- **`/proc` 是伪造的**。某些依赖真实 `/proc` 的工具（含部分 `node-pty` 场景）行为可能异常
- **Android 的限制不会消失**。phantom process killer、SELinux、FUSE `/sdcard` 全都还在

---

## 3. 封装 APK

### 它是怎么工作的

把 Termux（或自建的用户态）与预置的 dsh 环境打进一个 APK，用户安装后打开即用。常见做法是把 Termux 的 bootstrap 和 `$PREFIX` 一起打包。

### 优势

1. **对最终用户零门槛**。装上就能用，不需要理解 Termux、`pkg`、编译
2. **环境完全可控**。原生模块预编译好，不会因设备差异编译失败
3. **可以做前台服务**。用 `ForegroundService` 持通知，对抗 phantom process killer 比 `termux-wake-lock` 更可靠
4. **可做权限与数据边界**。能给 App 独立 data 目录

前提条件：

| 优势 | 前提条件 |
|---|---|
| 零门槛 | 有人愿意持续维护和发布 |
| 环境可控 | 只对预置的 ABI/Android 版本范围可控；跨版本仍可能坏 |
| 前台服务 | 需要写 Android 原生代码，不是纯脚本能做的 |
| 数据边界 | 仅限 App 私有目录；`/sdcard` 仍是 FUSE |

### 代价

- **维护成本极高**。你要跟进 Termux bootstrap、Node 版本、dsh 版本、Android 版本，任何一环变化都要重新打包
- **无法自助排错**。用户看不到 shell，出错只能靠日志上报，而日志往往不可得
- **分发受限**。Google Play 对这类"自带运行时的终端 App"有政策限制，通常只能侧载
- **安全责任转移**。你打包的东西在用户设备上以你的名义运行
- **体积**。1–2 GB 的 APK，更新一次全量下载

---

## 横向对比：本仓库遇到的 11 个问题，三条路各自如何

| 问题 | Termux 原生 | proot Ubuntu | 封装 APK |
|---|---|---|---|
| 无 android 版 `node-addon-require-builtin` | 补丁 09/10 | ✅ 不存在（有 linux 预编译） | 预置解决 |
| 无 `/bin/bash` | 补丁 01 | ✅ 不存在 | 预置解决 |
| `link(2)` 被 SELinux 拒绝 | 补丁 02 | ⚠️ 仍存在 | ⚠️ 仍存在 |
| `bubblewrap` 不可用 | 补丁 07（proot，partial） | ⚠️ 仍存在 | ⚠️ 仍存在 |
| `@vscode/ripgrep` 无 android 包 | 补丁 08 | ✅ 不存在 | 预置解决 |
| `koffi` 的 `statx()` | `koffi-statx.patch` | ⚠️ 视 bionic/glibc 而定 | 预置解决 |
| 原生模块编译失败 | ⚠️ 高发 | ✅ 用预编译 | 预置解决 |
| `libreoffice` 文档转换 | ❌ 不可用 | ✅ `apt install` 可行 | 视打包 |
| phantom process killer | ⚠️ 需 wake-lock | ⚠️ 同左 | ✅ 可用前台服务 |
| `/sdcard` FUSE 限制 | ⚠️ 存在 | ⚠️ 存在 | ⚠️ 存在 |
| dsh 版本漂移 | ⚠️ 补丁需重验 | ✅ 无补丁 | ⚠️ 需重新打包 |

---

## 什么情况下**不应该**用本仓库（Termux 原生）

明确写出来，避免误用：

1. **你要拿它做生产服务。** dsh 上游是 `0.2.2-rc.1`（RC 版本），本仓库是社区补丁集，两者都不承诺稳定。
2. **你需要真正的沙箱隔离。** 这里的沙箱是 `proot`，`read-only` 不生效、宿主文件系统可见、uid 不变 —— 它不能阻止模型越权读写。**要隔离请用远程 Linux 主机或独立设备。**
3. **你不能接受"升级即坏"。** 每次 `npm i -g @deepseek-ai/dsh` 都要重跑 `install.sh`，上游重构会让补丁失效。
4. **你不想碰编译工具链。** 需要 clang / cmake / NDK sysroot / node headers，缺一不可。
5. **你需要文档预览/转换（docx/xlsx/pdf）。** 这里没有 `libreoffice`，走 proot Ubuntu。
6. **你的设备不是 arm64。** 本仓库的原生产物与 NDK 布局只覆盖 aarch64。
7. **你的 Node 主版本低于 24。** 未验证，且 `internal/modules/*` 的形状在老版本上不同。
8. **你想用系统级 `apt` 装包。** Termux 是 `pkg`，包集合不同；复杂依赖（如 `libreoffice`）基本无解。

---

## 一句话总结

- **Termux 原生**：把 dsh 补到能在 bionic 上跑，换性能和环境互通，付出编译脆弱性 + 版本漂移 + 弱沙箱。
- **proot Ubuntu**：不补 dsh，改补环境，换兼容性和生态，付出性能税 + 体积 + 与 Termux 割裂。
- **封装 APK**：把复杂度转移给维护者，换用户体验，付出维护成本和分发自由。

三者都不是"官方方案"，也都不提供真正的安全隔离。
