# 排错手册（troubleshooting）

按「**报错现象 → 原因 → 解决方案 → 是否彻底解决**」组织。所有条目都是在本仓库验证环境上真实出现过的，不是猜测。

严格区分三种结局：

| 标记 | 含义 |
|---|---|
| **已彻底解决** | 有代码补丁，且补丁覆盖了根因；升级后重跑 `install.sh` 即可恢复 |
| **部分缓解** | 症状消失，但根因仍在（平台限制 / 上游行为），只在特定路径上避险 |
| **无法解决** | Android 或上游的固有约束，只能规避或换方案 |

---

<a id="1-dsh-web-crashes-at-startup-no-usable-native-binding-found-for-node-addon-require-builtin-android-arm64"></a>
## 1. `dsh web` 启动即崩溃：`No usable native binding found for node-addon-require-builtin-android-arm64`

### 现象

```
dsh: fatal uncaught exception: Error: dsh: host preparation failed:
No usable native binding found for node-addon-require-builtin-android-arm64 (auto)
```

`dsh --help`、`dsh --version` 都正常，**只有真正启动 profile 时才崩**。堆栈指向 `dsh-app-boot/lib/index.js` 的 `internalModules()`。

### 原因

`@deepseek-ai/dsh` 依赖 `node-addon-require-builtin`，这个包通过 `optionalDependencies` 分发预编译二进制，清单里只有：

```
darwin-arm64 / darwin-x64
linux-arm64-gnu / linux-arm64-musl / linux-x64-gnu / linux-x64-musl
win32-arm64-msvc / win32-ia32-msvc / win32-x64-msvc
```

**没有 `android-arm64`**。而 `dsh-app-boot` 的 `internalModules()` 硬依赖它去拿 `internal/modules/esm/loader` 等 Node 内部模块。

关键在于：同仓库的 `dsh-hmr` 和 `cordis-plugin-loader` 本来就有「先试 `--expose-internals`，失败再回退原生模块」的写法（在 `try/catch` 里），唯独 `dsh-app-boot` 漏了这一步。所以这是上游的不一致，不是 Android 独有的设计缺陷 —— 只是只有非桌面平台会踩到。

### 解决方案

补丁 [`patches/09-app-boot-expose-internals.patch`](patches/09-app-boot-expose-internals.patch)：把 `internalModules()` 改成与 `dsh-hmr` 一致的 `requireInternal()` 形式，优先走 `--expose-internals`。

同时需要保证进程真的带上了这个 flag。`install.sh` 做了两件事：

1. 改写 `$(npm root -g)/@deepseek-ai/dsh/lib/bin.js` 的 shebang
2. 往 `~/.bashrc` 追加 `alias dsh=...`

验证：

```bash
head -1 "$(npm root -g)/@deepseek-ai/dsh/lib/bin.js"
# 期望末尾带 --expose-internals
bash healthcheck.sh   # 看第 2 节
```

### 是否彻底解决

**部分缓解。** 补丁让当前版本可用，但：

- 上游若哪天给 `node-addon-require-builtin` 补上 android 产物，这个补丁就变成多余（但不会出错）
- **`npm i -g @deepseek-ai/dsh` 升级会覆盖补丁，崩溃立即复现**
- 任何绕过 shebang 直接 `node <dsh>/lib/bin.js` 的调用都会重现

→ 升级后必须重跑 `bash install.sh`。

---

<a id="2-the-browser-shows-dsh-web-authentication-required-reopen-the-url-printed-by-dsh-web"></a>
## 2. 浏览器打开后显示 `dsh web authentication required; reopen the URL printed by dsh web.`

### 现象

终端打印了带 token 的地址，在浏览器打开却得到一个纯文本 401 页面：

```
dsh web authentication required; reopen the URL printed by dsh web.
```

用 `curl` 拿同一个 URL 却是 **200**。

### 原因

dsh 下发的认证 cookie 带 `SameSite=Strict`（见 `dsh-client-connection/lib/index.js` 的 `sessionCookie()`）：

```
set-cookie: dsh-auth-…=v1.…; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict
HTTP/1.1 303 See Other
location: ./
```

`SameSite=Strict` 的 cookie **在同一次跨站导航链里不会被发送**。从 Termux 用 `termux-open-url` 拉起浏览器属于「外部 App 发起的跨站导航」：

```
Termux →(跨站)→ /?token=xxx →303 + Set-Cookie → /   ← 这一跳没带 cookie → 401
```

`curl` 能通是因为 curl 不实现 SameSite 规则，不是 dsh 的问题。

### 解决方案

任选其一：

- **手动把完整 URL 粘贴进浏览器地址栏再回车**（浏览器自身发起的导航不算跨站）
- 或看到 401 页面后**直接刷新**

token 本身可重复使用，不需要重启服务。

### 是否彻底解决

**未解决，只能规避。** 要根治需要把 cookie 改成 `SameSite=Lax`（在非 HTTPS 监听器上），这属于削弱 CSRF 防护的改动，本仓库**没有**做。

---

## 3. `gyp: Undefined variable android_ndk_path`

### 现象

`npm install -g @deepseek-ai/dsh` 或重装时，`node-pty` 编译阶段报：

```
gyp: Undefined variable android_ndk_path in .../common.gypi
```

### 原因

Termux 的 Node 用 Android NDK sysroot 编译原生模块，需要 `android_ndk_path` 指向 `$PREFIX`。node-gyp 缓存的 `common.gypi` 里没有这个默认值。

另外还有时序问题：旧版安装流程让 npm 在 `npm install -g` 阶段就跑 koffi/node-pty 的 install script，此时构建环境（node headers、`GYP_DEFINES`、`common.gypi` 的默认值）**尚未准备好**。

### 解决方案

`install.sh` 用两阶段安装规避：

1. `npm install -g --ignore-scripts`（先不编译）
2. 预热 node-gyp headers、把 `android_ndk_path` 默认值写进缓存的 `common.gypi`、应用 koffi 的 statx 补丁
3. 环境就绪后才手动编译原生模块

同时导出：

```bash
export GYP_DEFINES="android_ndk_path=$PREFIX"
```

### 是否彻底解决

**已彻底解决**（针对本仓库的安装路径）。但如果你直接 `npm i -g @deepseek-ai/dsh` 而不用 `install.sh`，会重新踩到。

---

## 4. `fatal error: 'node.h' file not found`

### 现象

编译 `node-pty` / `koffi` 时找不到 Node 头文件。

### 原因

node-gyp 需要 `~/.cache/node-gyp/<node版本>/` 下的头文件。全新设备上该缓存为空，node-gyp 会去 `nodejs.org` 现场下载 —— 慢速或被墙时直接失败。

### 解决方案

`install.sh` 会预先下载并解压对应版本的头文件到缓存目录，并**刻意不导出** `npm_config_nodedir`（导出它会让后续每次 npm 调用都打印 `npm warn Unknown env config nodedir`）。

手动修复：

```bash
NODE_VER="$(node -v | sed 's/^v//')"
mkdir -p "$HOME/.cache/node-gyp/$NODE_VER"
curl -fsSL "https://nodejs.org/download/release/v$NODE_VER/node-v$NODE_VER-headers.tar.gz" \
  | tar -xz -C "$HOME/.cache/node-gyp/$NODE_VER" --strip-components=1
```

### 是否彻底解决

**已彻底解决**。

---

## 5. `ripgrep launch failed`（glob / grep 工具全部不可用）

### 现象

Web UI 里让模型读文件列表或搜索，报 `ripgrep launch failed`。

### 原因

`@vscode/ripgrep` 通过 `@vscode/ripgrep-${platform}-${arch}` 解析二进制，在 Termux 上就是 `@vscode/ripgrep-android-arm64` —— **这个包不存在**。

### 解决方案

见 [`termux-ripgrep-fix.md`](docs/termux-ripgrep-fix.md)。两部分：

1. 建一个 shim 包 `@vscode/ripgrep-android-arm64`，`bin/rg` 软链到系统 `rg`
2. 补丁 [`patches/08-dsh-tool-fs-search-android-rg.patch`](patches/08-dsh-tool-fs-search-android-rg.patch) 让 `resolveRgPath()` 用 `require.resolve()` 试探 + 回退到系统 `rg`

只需要 `pkg install ripgrep` 保证系统 rg 存在。

### 是否彻底解决

**已彻底解决**（双保险：shim 存在则命中 shim，不存在则走补丁的系统回退）。

---

## 6. 会话保存/归档失败，或 `link(2)` 报 EACCES

### 现象

Android 上 `link(2)` 报 `EACCES`/`EPERM`；新建会话后拿不到持久化文件；归档按钮静默失败。

### 原因

两个独立原因叠在一起：

1. **SELinux 全线拒绝 `link(2)`**。在本仓库验证设备上，`$HOME` 和 `$PREFIX/tmp`（`u:object_r:app_data_file:s0`）都返回 `EACCES`。这不是 /sdcard 的问题，内部存储也一样。`healthcheck.sh` 第 8 节会实测出来。
2. **归档时会话不存在**：全新安装下，UI 里可见的会话可能不在持久化层（空会话目录、未持久化的实时会话），`sessionKnown()` 校验失败。

### 解决方案

- [`patches/02-session-persistence-link-rename.patch`](patches/02-session-persistence-link-rename.patch)：`link(2)` 遇到 `EACCES`/`EPERM` 时回退到同盘原子 `rename(2)`（已实测 `rename(2)` 在本设备可用）
- [`patches/06-workspace-archive-skip-session-known-check.patch`](patches/06-workspace-archive-skip-session-known-check.patch)：归档时跳过 `sessionKnown()` 校验

### 是否彻底解决

**已彻底解决**（`rename` 回退路径已验证可用）。但注意：

- 回退只在**同一文件系统内**是原子的。把 workspace 放在 /sdcard、`DSH_HOME` 放在内部存储，跨设备 rename 会退化成 copy+unlink，不再原子
- 归档校验被跳过意味着可能归档一个"不存在"的会话 —— 只是往列表里加一个 id，不会造成数据损坏

---

## 7. Bash 沙箱：`SandboxUnavailableError` 或"沙箱没隔离"

### 现象

- 早期版本：Android sepolicy 拒绝 `bwrap`，抛 `SandboxUnavailableError`
- 打上 proot 补丁后：命令能跑，但 `read-only` 策略不生效、沙箱里能看到整个家目录

### 原因

- `bubblewrap` 需要 `user_namespaces` 和特定 `/proc` 访问，Android sepolicy 拒绝
- `proot` 是 **ptrace 用户态重定向**，不是 namespace 隔离。它的 `-b` 绑定默认**读写**，无法表达只读语义

### 解决方案

[`patches/07-sandbox-local-proot-runner.patch`](patches/07-sandbox-local-proot-runner.patch)：把 `proot` 加进 Android 平台链，`enforcement` 标记为 `partial`，并把 `/tmp` 重定向到 `$PREFIX/tmp`（Termux 的 `/tmp` 只读）。

### 是否彻底解决

**无法解决 —— 这是设计上限，不是 bug。**

实测结论（Android 16 / SDK 36 / arm64）：

| 项 | 结果 |
|---|---|
| 命令执行 | ✅ |
| workspace 写入 | ✅ |
| `/tmp` 重定向 | ✅ |
| `read-only` 策略强制 | ❌ 仍可写入 |
| 宿主文件系统可见 | ❌ 完全可见 |
| 用户身份隔离 | ❌ uid 与宿主相同 |

**权限保护来自 dsh 自身的审批（approval）机制，不是来自这个沙箱。** 详见 README 的「局限与风险」。

---

## 8. `dsh plugin add github:...` 失败：`OpenSSL SSL_read: unexpected eof while reading`

### 现象

```
ERR_PNPM_GIT_RESOLVE_FAILED
Failed to resolve git dependency "github:xxx/yyy": git ls-remote failed:
fatal: unable to access 'https://github.com/...': OpenSSL SSL_read: ... errno 0
```

### 原因

GitHub 的 TLS 握手被中途掐断（网络抖动 / 代理 / 移动网络对长连接不友好）。**不是配置错误**。

### 解决方案

直接重试。本仓库验证时第一次失败、几分钟后同样的命令成功：

```bash
bash healthcheck.sh   # 或直接
curl -s -o /dev/null -w '%{http_code}\n' https://github.com/
```

返回 `200` 就可以重跑 `dsh plugin add`。

若确实只能走 SSH：

```bash
git config --global url."git@github.com:".insteadOf "https://github.com/"
```

（这会改变 lockfile 记录的 transport，仅在 HTTPS 完全不可用时使用。）

### 是否彻底解决

**部分缓解。** 根因在网络，无法在本地解决。

---

## 9. 用着用着突然连不上（后台 node 被系统杀掉）

### 现象

`dsh web` 运行一段时间后无响应，进程消失，日志没有异常。

### 原因

Android 12+（本设备 Android 16 / SDK 36）的 **phantom process killer** 会回收后台进程，包括 Termux 里的 `node`。

### 解决方案

两件都要做：

```bash
termux-wake-lock      # 持 wakelock；不用时 termux-wake-unlock
```

并在 **设置 → 应用 → Termux → 电池 → 无限制**（只能手动点）。

### 是否彻底解决

**部分缓解。** 该机制无法完全关闭，只能降低被杀概率。生产用途请用 `proot` Ubuntu 或独立设备。

---

## 10. `require('@img/sharp-wasm32')` 报 `ERR_PACKAGE_PATH_NOT_EXPORTED`

### 现象

```
Error [ERR_PACKAGE_PATH_NOT_EXPORTED]: No "exports" main defined in
.../node_modules/@img/sharp-wasm32/package.json
```

### 原因

`@img/sharp-wasm32` 不提供 `exports` 的 main 入口，只能被 `sharp` **按内部路径**引用。单独 `require` 它本来就是错的。

### 解决方案

不需要解决。验证 `sharp` 本身是否可用即可：

```bash
cd "$(npm root -g)/@deepseek-ai/dsh" && node -e '
const s = require("sharp");
s({create:{width:8,height:8,channels:3,background:{r:1,g:2,b:3}}}).png().toBuffer()
 .then(b => console.log("sharp OK", b.length, "bytes"));
'
```

`healthcheck.sh` 第 3 节会自动做这个检查。

### 是否彻底解决

**不是问题**，是误报。

---

## 11. `require('node-addon-require-builtin')` 加载失败

### 现象

```
Error: No usable native binding found for node-addon-require-builtin-android-arm64 (auto)
```

### 原因

同 [问题 1](#1-dsh-web-启动即崩溃no-usable-native-binding-found-for-node-addon-require-builtin-android-arm64) —— 缺 android 预编译产物。

### 解决方案

打上 09/10 补丁后，dsh **不再走这条路径**，这个错误在正常运行中是预期且无害的。`healthcheck.sh` 会把它报成 OK（"expected"）。

真正需要警惕的是相反情况：如果它**能**加载成功，说明有人改动了回退顺序。

### 是否彻底解决

**已绕过。** 永久解决需要上游发布 android 产物。

---

## 12. `dsh-web-mobile` 装不上 / 装上但窄屏布局没变化

### 现象

安装脚本第 7 步 `dsh plugin add github:mexiaosqwq/dsh-web-mobile` 失败；或装了但手机上还是桌面版布局。

### 原因

- 安装失败：见 [问题 8](#8-dsh-plugin-add-github-失败openssl-ssl_read-unexpected-eof-while-reading)（网络）
- 布局无变化：**需要重启 `dsh web`**。插件是启动时组装的，热加载不一定能把客户端样式注入现有页面

### 解决方案

```bash
dsh plugin --profile web add github:mexiaosqwq/dsh-web-mobile
# 然后必须重启
pkill -f 'bin\.js web'   # 或用自己的 PID 文件管理脚本
dsh web --no-open
```

新 token 会重新打印。

> ⚠️ 不要用 `pkill -f "dsh web"`：你自己的 shell 命令行里也含这个字符串，会把当前会话一起杀掉（退出码 143）。用 PID 文件或更精确的 pattern。

### 是否彻底解决

**已彻底解决**（重启后生效）。

---

## 13. 文档预览 / 转换全部失败

### 现象

打开 docx / xlsx / pptx / pdf 时预览为空或报错。

### 原因

`libreoffice-kit` 需要 `libreoffice` 可执行文件。Termux 上安装它极其困难（体积大、依赖 glibc 组件）。

### 解决方案

无。建议**当作该功能不存在**。

### 是否彻底解决

**无法解决。** 属于能力缺失，不是可修复的 bug。

---

## 14. Android 上 `/tmp` 不可写

### 现象

脚本或沙箱内往 `/tmp` 写文件报 `Read-only file system`。

### 原因

Termux 的 `/tmp` 是只读挂载。可写位置是 `$PREFIX/tmp`。

### 解决方案

- 补丁 07 已把沙箱内的 `/tmp` 绑定到 `$PREFIX/tmp`
- 自己的脚本请统一用 `$TMPDIR`（Termux 下它已指向 `$PREFIX/tmp`）

### 是否彻底解决

**已彻底解决**（在沙箱和本仓库脚本范围内）。

---

## 15. 上游升级后一切回到原点

### 现象

`npm update -g @deepseek-ai/dsh` 之后，`dsh web` 又崩溃了，行为和刚装好 Termux 时一样。

### 原因

npm 重新解包 `@deepseek-ai/dsh`，把 `node_modules/@deepseek-ai/*` 下的所有补丁**全部覆盖**。`bin.js` 的 shebang 也被重置。

### 解决方案

```bash
cd ~/deepseek-harness-termux && bash install.sh
```

`install.sh` 是幂等的：已应用的补丁跳过，已编译的产物跳过；但被覆盖掉的补丁会被重新应用。

**版本漂移警告**：补丁是按 `@deepseek-ai/dsh` 0.2.2-rc.1 的源码上下文生成的（`diff -u` 精确匹配）。上游改动过大时 `patch` 会拒绝应用，脚本会打印 `[SKIP] ... inapplicable`。此时需要重新生成补丁，不能盲目重跑。

### 是否彻底解决

**无法彻底解决** —— 这是「对上游包打补丁」这种方案的结构性代价。只能靠升级后重跑 + 关注 `[SKIP]` 输出。

---

## 16. 会话写入报 `ERR_FLOCK_UNSUPPORTED_PLATFORM: flock is not supported on android-arm64`

### 现象

新建会话、让会话落盘或归档时，持久化失败并报：

```
ERR_FLOCK_UNSUPPORTED_PLATFORM: flock is not supported on android-arm64
```

会话写锁 `SessionWriteLease.acquire()` 拿不到内核锁，非 EAGAIN/EWOULDBLOCK 的错误会原样上抛。

### 原因

1. Termux 的 Node 报告 `process.platform === 'android'`（不是 `linux`）。
2. `@deepseek-ai/node-addon-system/lib/flock.js` 只放行 `linux` / `darwin`，其余平台直接抛 `ERR_FLOCK_UNSUPPORTED_PLATFORM`。
3. 即使放行，它会去解析 `@deepseek-ai/node-addon-system-android-arm64` —— 上游根本没发布这个平台包；而且 Android 是 bionic libc，既非 glibc 也非 musl，现有 linux 预编译二进制（glibc/musl 两个子目录）也无法加载。

### 解决方案

Android bionic 本身实现了 `flock(2)`（`<sys/file.h>`），且 `flock.c` 是自包含的纯 N-API（ABI 稳定），所以按三条路径修复：

1. **补丁 11**（`patches/11-node-addon-system-flock-android.patch`）：把 `android` 当作 POSIX 平台放行，并在 Android 上跳过 glibc/musl 子目录选择，直接用 `bin/system.node`。
2. **`install.sh` 新增 5d**：用 `clang -shared -fPIC -O2` 把 `src/flock.c` 编译成 `system.node`（android-arm64），并生成 shim 包 `@deepseek-ai/node-addon-system-android-arm64`。
3. **Plan B（`prebuilt/install.js` + `build-prebuilt.sh`）**：同样应用补丁 11、落预编译 `system.node`、建 shim 包；layered 包把 `system.node` 打进 `prebuilt/android-arm64/`，full 包的验证阶段也测 flock。

重新安装：

```bash
cd ~/deepseek-harness-termux && bash install.sh
```

### 是否彻底解决

**已彻底解决**（android-arm64 上 `flock` 加锁返回 0，竞争返回 EAGAIN=11，与 `SessionAlreadyOwnedError` 分支正确对应）。

---

## 快速自检

不确定当前状态时，先跑：

```bash
cd ~/deepseek-harness-termux && bash healthcheck.sh
```

任何 `[FAIL]` 都对应上面某一条。
