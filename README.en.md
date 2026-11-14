# deepseek-harness-termux

> A minimal but working patch-and-gotcha collection for running **dsh** on **native Termux**. Not an official solution, and not guaranteed to keep working across versions.
>
> This repository continues the upstream work of [Vengisk/deepseek-harness-termux](https://github.com/Vengisk/deepseek-harness-termux): the patch approach, troubleshooting findings and prebuilt packaging all originate there. On top of that, this fork adds the dsh `0.2.2-rc.3` port, the boot-critical patches (09/10/11), install-time preflight validation and a documentation rewrite. Upstream authorship is preserved in the commit history.

[`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness) (DeepSeek Harness) is published as a glibc Linux package. On Android/Termux it fails to start in a way that is hard to diagnose yourself — not because a dependency is missing, but because an **android-arm64 build of a required native addon simply does not exist**.

This repository does not give dsh a Linux environment. It **patches the Android incompatibilities one by one**: 12 source patches, on-device compilation of the native modules, and a self-check script that tells you what is actually broken right now.

Every claim maps to a reproducible step or an error message — see [`troubleshooting.md`](troubleshooting.md).

简体中文（主文档）: [`README.md`](README.md)

---

## Contents

- [Quick start](#quick-start)
- [Verified environment (verification boundary)](#verified-environment-verification-boundary)
- [Advantages](#advantages)
- [Limitations and risks](#limitations-and-risks)
- [Known issues](#known-issues)
- [Who this is for](#who-this-is-for)
- [Who should NOT use this](#who-should-not-use-this)
- [Patch list](#patch-list)
- [Self-check](#self-check)
- [Route comparison](#route-comparison)
- [Disclaimer](#disclaimer)

---

## Quick start

### Prerequisites

```bash
pkg update -y && pkg upgrade -y
pkg install -y nodejs-lts binutils make pkg-config clang python cmake patch git proot which ripgrep
```

`install.sh` installs anything missing, but doing this first surfaces failures earlier.

### Plan A — compile on device (full control)

```bash
git clone https://github.com/y0u41/deepseek-harness-termux.git
cd deepseek-harness-termux
bash install.sh          # 5–15 min; compiles node-pty / koffi on device
dsh web
```

### Plan B — precompiled native modules (**not published yet**)

> ⚠️ No release with prebuilt tarballs has been published, so there is no
> `npm i -g <url>` shortcut yet. Use Plan A. If you would rather not compile on
> a second device, build the tarballs once on a working install:

```bash
# 1. get a working install (this compiles the natives once)
bash install.sh
# 2. package it into redistributable tarballs
bash scripts/build-prebuilt.sh
```

That produces `dsh-termux.tgz` (layered, ~360 KB) and
`dsh-termux-full.tgz` (vendored, ~110 MB). Install them on another arm64 device:

```bash
# vendored: self-contained, nothing else to run
npm i -g ./dsh-termux-full.tgz
dsh web

# layered: npm 12 needs the extra step
npm i -g ./dsh-termux.tgz
dsh-termux-setup
dsh web
```

> **Why the layered variant needs `dsh-termux-setup`**: since npm 12, a
> dependency's `postinstall` does not run unless it is allow-listed
> (`allowScripts`) — and npm still exits 0. A bare `npm i -g` leaves an
> "installed" package with no dsh inside (`dsh: command not found`).
> `dsh-termux-setup` is an explicit bin that always runs; the `dsh` launcher
> also self-bootstraps when the deployment is missing.

See [`prebuilt/README.md`](prebuilt/README.md).

### Opening the UI

`dsh web` prints a tokened URL:

```
dsh web: http://127.0.0.1:3080/?token=xxxxxxxx
```

> ⚠️ **Paste the full URL into the browser address bar, or reload once after it opens.**
> Opening it by app-to-app handoff (`termux-open-url`) returns 401, because the auth cookie is `SameSite=Strict`. Cause and workaround: [`troubleshooting.md` problem 2](troubleshooting.md#2-the-browser-shows-dsh-web-authentication-required-reopen-the-url-printed-by-dsh-web).

### Stopping it safely

Do **not** use `pkill -f "dsh web"` — your own shell's command line contains that string and gets killed too (exit code 143). Track a PID instead.

---

## Verified environment (verification boundary)

The only combination that has been **actually run end-to-end and fully self-checked**. Everything else is marked **unverified**.

| Item | Verified value | Note |
|---|---|---|
| Architecture | `aarch64` | **arm64 only.** x86_64 unverified; the natives and NDK layout here are aarch64-only |
| Android | **16** (SDK 36) | Unverified: Android 8–15 and 17+ |
| Termux | `0.119.0-beta.3` | From F-Droid. Play Store build unverified (generally obsolete) |
| Node.js | **v26.13.0** (ABI 147) | Requires ≥ **24.9.0** (dsh’s own engines). Unverified: Node 20 / 22 / 24.0–24.8 |
| npm | `12.2.2` | |
| pnpm | `12.18.0` | Needed for plugin management |
| clang | `21.1.8` | Needed to compile the natives |
| ripgrep | `15.2.0` (`+pcre2`) | |
| proot | Termux `proot` package | Sandbox runner |
| dsh | **`0.2.2-rc.3`** | Patches were generated against this upstream source. Other versions **unverified** |
| SELinux context | `u:object_r:app_data_file:s0:c20,c257,c512,c768` | Under this context `link(2)` is **denied everywhere** — see patch 02 |
| Shared storage | `/sdcard` available (FUSE) | FUSE semantics still apply |

**Explicitly unverified:**

- Node 20 / 22 / 24.0–24.8 (`internal/modules/*` changed shape around 24.12; patch 09’s fallback assumes 24.9+)
- Android 8–15, 17+
- x86_64 / armeabi-v7a
- Non-Termux Android terminals (UserLAnd, Andronix, …)
- Any dsh version other than 0.2.2-rc.3
- The Play Store build of Termux

---

## Advantages

| # | Advantage | Precondition (without it, this is not an advantage) |
|---|---|---|
| 1 | **No intermediary layer — performance closest to native.** Node runs directly on the Android kernel; no rootfs, no proot syscall translation | The natives must compile on device. If compilation fails there is no performance to speak of |
| 2 | **Naturally integrated with Termux.** dsh's shell *is* your Termux shell; `pkg`-installed tools and `$PREFIX` binaries are directly usable, no `--bind` mapping | You actually want the Termux toolchain. If you prefer the apt ecosystem this is not an advantage |
| 3 | **Smallest footprint** — no extra 1–2 GB rootfs | Excludes the `pkg` packages you still need (clang, cmake, ripgrep: hundreds of MB) |
| 4 | **Fastest start** — no chroot/proot init overhead | The difference is seconds; cold start is dominated by Node itself |
| 5 | **Android integration works** — patch 04 makes "Open in app" actually fire an Android intent via `termux-open` | Termux environment only; inside proot it needs extra bridging |
| 6 | **Every patch has a concrete failure signal** — not "it runs", but each is verifiable with one command | You have to be willing to run `healthcheck.sh` and read the output |
| 7 | **The self-check distinguishes "broken" from "documented limit"** — `healthcheck.sh` emits `FAIL` vs `WARN` | `WARN` still requires you to understand it, otherwise it looks like breakage |

---

## Limitations and risks

| # | Limitation / risk | Impact | Mitigation |
|---|---|---|---|
| 1 | **The sandbox is not a security boundary** (proot `enforcement: partial`) | The `read-only` policy is **not enforced**; the sandbox can see the whole host filesystem; uid is unchanged. Cannot stop the model from reading/writing `~/.ssh` or `~/.dsh/.credentials.yaml` | Rely on dsh's own approval mechanism. For real isolation use a remote Linux host or a separate device |
| 2 | **Native compilation is fragile** | Any of clang / cmake / NDK sysroot / node headers / `common.gypi` failing aborts the build, and the error rarely names the real cause | `install.sh` does a two-phase install (`--ignore-scripts` first, compile only once the environment is ready); see [`troubleshooting.md` 3/4](troubleshooting.md); or use Plan B |
| 3 | **dsh version drift** | `npm i -g @deepseek-ai/dsh` overwrites every patch and the shebang; the boot crash returns immediately. Upstream refactors make `patch` refuse to apply | **You must** re-run `bash install.sh` after any upgrade; watch for `[SKIP] ... inapplicable` in the output — that means patches need regenerating |
| 4 | **`link(2)` denied by SELinux everywhere** | Atomic writes for session persistence and workspace archiving fail (`EACCES`/`EPERM`) | Patch 02 falls back to a same-filesystem atomic `rename(2)` (verified working). **Note:** atomicity only holds if workspace and `DSH_HOME` are on the same filesystem |
| 5 | **`/sdcard` is FUSE** | No hard links, no exec bit, no symlinks, case-insensitive, different `rename` semantics | Keep `DSH_HOME` and workspaces on internal storage (`$HOME`). `healthcheck.sh` section 8 measures it and `FAIL`s if you cross the line |
| 6 | **Android 12+ phantom process killer** | Background `node` may be reaped — "it worked, then suddenly the connection dropped" | `termux-wake-lock` plus Settings → Apps → Termux → Battery → Unrestricted. Reduces the chance only; cannot be disabled |
| 7 | **Document preview/conversion unavailable** | docx / xlsx / pptx / pdf preview and conversion fail (`libreoffice-kit` needs `libreoffice`) | None. Installing `libreoffice` on Termux is effectively impossible; use proot Ubuntu for this |
| 8 | **aarch64 only** | x86_64 / armv7 devices cannot use these natives or the NDK layout | None. Use proot Ubuntu (has linux-arm64-gnu prebuilds) |
| 9 | **Sensitive to the Node major version** | Node < 24.9.0 unverified (dsh engines is `>=24.9.0`); `internal/modules/*` changed shape around 24.12 and patch 09's fallback assumes 24+ | Use the latest `pkg install nodejs-lts`; rebuild the natives via `install.sh` after a Node major upgrade |
| 10 | **Large install footprint** | Full dsh is ~**750 MB** (includes `@img/sharp-wasm32` WASM artifacts); `~/.dsh` ~8 MB | Cannot be meaningfully reduced; low-storage devices should use Plan B's layered variant |
| 11 | **Auth cookie is `SameSite=Strict`** | Opening the Web UI via an external app handoff yields 401 | Paste the URL into the address bar manually, or reload once. No `SameSite=Lax` patch is shipped (that would weaken CSRF protection) |

---

## Known issues

Only issues that **still exist and are not fully resolved**. Each states its outcome.

### 1. No sandbox isolation — partially mitigated, cannot be fixed

`bubblewrap` needs `user_namespaces`, which Android sepolicy denies. The harness probes `proot → bwrap → landlock`, settles on `proot`, and marks `enforcement: "partial"`.

Measured (Android 16 / SDK 36 / arm64):

| Test | Result |
|---|---|
| Command execution (`read-only` / `workspace-write`) | ✅ exit 0 |
| Write inside workspace and read back | ✅ |
| `/tmp` redirect to `$PREFIX/tmp` | ✅ |
| **Is the `read-only` policy enforced?** | ❌ **No** — the write still succeeded |
| **Host filesystem visibility** | ❌ **Fully visible** |
| **Process identity** | ❌ `uid` identical to host |
| **namespace / seccomp** | ❌ Neither (proot is a ptrace user-space redirect) |

**The protection you get comes from dsh's approval mechanism, not from this sandbox. Do not treat it as a container.**

### 2. Upstream ships no android prebuild — worked around, not fixed

`node-addon-require-builtin`'s `optionalDependencies` cover darwin / linux / win32 only — **no android-arm64**. Patches 09/10 route dsh through `--expose-internals` instead, which means **the whole of dsh depends on that flag**:

- `install.sh` rewrites the `lib/bin.js` shebang and appends a `~/.bashrc` alias
- Any invocation that bypasses the shebang (`node <dsh>/lib/bin.js`) reproduces the crash
- Any upgrade that overwrites the patches reproduces the crash

### 3. Document conversion missing — unresolvable

Requires the `libreoffice` executable. Assume the feature does not exist.

### 4. Background survival not guaranteed — partially mitigated

The Android 12+ phantom process killer cannot be disabled; only `termux-wake-lock` + disabling battery optimisation.

### 5. Patches are tightly coupled to one upstream version — structural cost

Generating `diff -u` patches against `@deepseek-ai/dsh` **0.2.2-rc.3** means any upstream refactor can make `patch` refuse to apply. This is not fixable — it is the inherent cost of patching someone else's package.

---

## Who this is for

- People willing to tinker, who read the error before acting
- People who **need dsh on native Termux** (`$PREFIX`, `pkg` ecosystem, their existing Termux toolchain)
- People who want to understand how Node native modules, SELinux and FUSE each break on Android
- People who accept "re-run the installer after every dsh upgrade"
- People treating this as a **personal dev/experiment tool**, not a public service

## Who should NOT use this

| Your need | Why this does not fit | Alternative |
|---|---|---|
| **Production-grade stability** | dsh itself is `0.2.2-rc.3` (an RC) and this is a community patch set; neither promises stability | Remote Linux host + official dsh |
| **Full sandbox / real isolation** | The sandbox is proot: `read-only` not enforced, host FS visible, uid unchanged | Separate device, Android work profile, remote Linux |
| **Zero debugging tolerance** | bionic/glibc differences, SELinux, FUSE — you may have to tell them apart yourself | proot Ubuntu, or a packaged APK |
| **System-level package management** | Termux uses `pkg`; complex deps (e.g. `libreoffice`) are effectively unsolvable | proot Ubuntu |
| **Document preview/conversion** | No `libreoffice` | proot Ubuntu |
| **No compilation at all** | Plan A needs clang / cmake / NDK sysroot | Plan B, or proot Ubuntu |
| **Non-arm64 device** | The natives and NDK layout are aarch64-only | proot Ubuntu |
| **Node < 24.9.0** | Unverified; `internal/modules/*` shape differs | Upgrade Node, or proot Ubuntu |
| **Handing it to non-technical users** | It requires reading terminal errors | A packaged APK |

---

## Patch list

| Patch | Target package | What it fixes |
|---|---|---|
| [`01-terminal-bash-android-shell.patch`](patches/01-terminal-bash-android-shell.patch) | `dsh-terminal-bash` | Resolves a shell that actually exists (Android has no `/bin/bash`) |
| [`02-session-persistence-link-rename.patch`](patches/02-session-persistence-link-rename.patch) | `dsh-session-persistence-jsonl` | Falls back to same-fs atomic `rename(2)` when `link(2)` is denied (`EACCES`/`EPERM`) |
| [`03-subprocess-local-android.patch`](patches/03-subprocess-local-android.patch) | `dsh-subprocess-local` | Treats `android` like `linux` for the process-group check (`kill(-pid, 0)`) |
| [`04-native-command-termux-open.patch`](patches/04-native-command-termux-open.patch) | `dsh-native-command` | Uses `termux-open` for paths/URLs on Android; enables native path detection |
| [`05-host-directory-picker-native-android.patch`](patches/05-host-directory-picker-native-android.patch) | `dsh-host-directory-picker-native` | No longer throws “unsupported” on Android, it probes zenity/kdialog — neither exists on Termux, so **directory picking still does not work**; only the error message becomes accurate. Use the in-app browse picker |
| [`06-workspace-archive-skip-session-known-check.patch`](patches/06-workspace-archive-skip-session-known-check.patch) | `dsh-workspace` | Skips `sessionKnown()` when archiving (fails on fresh installs) |
| [`07-sandbox-local-proot-runner.patch`](patches/07-sandbox-local-proot-runner.patch) | `dsh-sandbox-local` | Adds `proot` to the Android chain with `enforcement: partial`; redirects `/tmp` to `$PREFIX/tmp` |
| [`08-dsh-tool-fs-search-android-rg.patch`](patches/08-dsh-tool-fs-search-android-rg.patch) | `dsh-util-ripgrep` | `require.resolve()` + system-rg fallback; `@vscode/ripgrep` has no android-arm64 package (see [`docs/termux-ripgrep-fix.md`](docs/termux-ripgrep-fix.md)) |
| [`09-app-boot-expose-internals.patch`](patches/09-app-boot-expose-internals.patch) | `dsh-app-boot` | `internalModules()` tries `--expose-internals` first, then the native addon |
| [`10-inspector-worker-expose-internals.patch`](patches/10-inspector-worker-expose-internals.patch) | `dsh-experimental-inspector` | Worker `execArgv` `[]` → `["--expose-internals"]` (workers do not inherit parent flags) |
| [`11-node-addon-system-flock-android.patch`](patches/11-node-addon-system-flock-android.patch) | `node-addon-system` | `flock.js` accepts the `android` platform; with install.sh step 5d compiling the android-arm64 `system.node`, session write locks no longer throw `ERR_FLOCK_UNSUPPORTED_PLATFORM` |
| [`koffi-statx.patch`](patches/koffi-statx.patch) | `koffi` | Conditionally compiles out `statx()`, absent from bionic |

Patches 09/10 are the two that fail most easily and also the two that make "it mysteriously works again". See [`troubleshooting.md` problem 1](troubleshooting.md#1-dsh-web-crashes-at-startup-no-usable-native-binding-found-for-node-addon-require-builtin-android-arm64).

---

## Self-check

```bash
bash healthcheck.sh            # human-readable report
bash healthcheck.sh --quiet    # exit code only (0 = no FAIL)
bash healthcheck.sh --verbose  # extra detail
```

Covers:

1. Platform / toolchain (Android, `$PREFIX`, Node version and ABI, dsh version, disk)
2. **`--expose-internals` reachability** (shebang, `internal/modules/*`, whether the native addon was unexpectedly enabled)
3. Native modules (`node-pty`, `koffi`, real `sharp` encode/decode, real PTY spawn)
4. Search backend (rg, `@vscode/ripgrep-android-arm64` shim)
5. Patch coverage (per-patch `patch --dry-run --reverse`; if upstream has already folded the same change in, a behaviour probe reports *obsolete* instead of a false `NOT applied`)
6. Sandbox capability (proot executability + an explicit partial-enforcement note)
7. Port occupancy (connect probe + unauthenticated request must return 401)
8. **`/sdcard` and FUSE risks** (measures `link(2)` / `rename(2)`, checks whether `DSH_HOME` sits on shared storage)
9. Credentials (presence and 600 permission)
10. Background survival (SDK version and `termux-wake-lock`)

`WARN` is a documented platform limit, not breakage. `FAIL` is what needs action.

---

## Route comparison

Native Termux vs proot Ubuntu vs a packaged APK — performance, footprint, sandboxing, maintenance cost, and how each of this repo's 11 problems behaves on each route: [`docs/comparison.md`](docs/comparison.md).

---

## Project layout

```
deepseek-harness-termux/
├── README.md                  # Chinese primary document
├── README.en.md               # this file
├── troubleshooting.md         # symptom → cause → fix → is it really fixed?
├── healthcheck.sh             # post-install self-check
├── install.sh                 # idempotent installer with env validation
├── LICENSE                    # MIT
├── docs/
│   ├── comparison.md          # three-route comparison
│   └── termux-ripgrep-fix.md  # ripgrep fix details
├── patches/                   # 12 source patches (applied with patch -p1 per package)
├── prebuilt/                  # Plan B: precompiled deployment package
└── scripts/                   # maintainer scripts (build prebuilt artifacts, …)
```

---

## Disclaimer

1. **Not official.** Community-maintained; unaffiliated with and not endorsed by DeepSeek AI or the `deepseek-harness` project.
2. **No stability promise.** `@deepseek-ai/dsh` is currently `0.2.2-rc.3` (an RC). These patches target that source and are **not guaranteed to work across versions**.
3. **No security promise.** The proot sandbox is **not a security boundary**: `read-only` is not enforced, the host filesystem is visible, and process identity is not isolated. **Do not let it run untrusted commands on a device holding sensitive credentials.**
4. **Use at your own risk.** The installer modifies a global npm package (`$(npm root -g)/@deepseek-ai/dsh`) and appends to `~/.bashrc` (append only — never rewritten). Run it knowing that.
5. **No warranty.** Under the MIT licence the software is provided "as is", without warranty of any kind.
6. **Data responsibility.** Keep working data on internal storage (`$HOME`). Never put `DSH_HOME` or workspaces on `/sdcard` — FUSE semantics will corrupt them.

---

## Acknowledgements

- **[DeepSeek AI](https://github.com/deepseek-ai)** — the [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) framework
- **[@mexiaosqwq](https://github.com/mexiaosqwq)** — the [dsh-web-mobile](https://github.com/mexiaosqwq/dsh-web-mobile) mobile UI plugin
- **The Termux community** — the Android terminal environment
- The maintainers of **koffi / node-pty / sharp**

## License

MIT — same as upstream [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness). See [LICENSE](LICENSE).
