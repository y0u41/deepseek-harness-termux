# dsh-termux — precompiled Termux deployment (Plan B)

English | [简体中文](README.zh-CN.md)

---

Installs the patched [`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness)
globally on Termux **without compiling anything**: the native modules
(`node-pty`, `koffi`) ship prebuilt for **android-arm64** (N-API — ABI stable
across Node versions), so no `clang`, `cmake`, NDK, or multi-minute builds are
needed.

## Install — two variants

> ⚠️ **No release with prebuilt tarballs has been published yet**, so the
> `releases/latest/download/...` URLs below do not resolve. Build the tarballs
> yourself first (`bash scripts/build-prebuilt.sh` on a working install), then
> install them locally as `npm i -g ./dsh-termux-full.tgz`.

### Vendored (fully self-contained, ~110 MB) — recommended

```bash
npm i -g ./dsh-termux-full.tgz
dsh web
```

> **This variant needs no setup step** — it contains the whole patched dsh,
> `dsh` is linked straight to `lib/bin.js`, and no lifecycle script runs.
> The layered variant below is the one affected by npm 12.
>
> **npm 12 and later: the layered variant needs `dsh-termux-setup`.** npm 12 does
> not run a dependency's `postinstall` unless it is allow-listed
> (`allowScripts`), and it still exits 0 — so `npm i -g` alone leaves an empty
> package behind (`dsh: command not found`). `dsh-termux-setup` is a plain bin,
> always executed. The `dsh` launcher also runs the setup by itself when it
> finds the deployment missing, so `dsh` alone usually suffices.

Bundles the **entire patched dsh + node_modules** (natives and sharp's wasm
included) — one self-contained artifact, one `npm i -g`, no compilation.
Like the reference `dsh-termux` package, npm may still consult the registry on
a cold npm cache; with a warm cache (or after a previous install) it installs
from the bundle quickly.

### Layered (small, ~360 KB)

```bash
npm i -g ./dsh-termux.tgz
dsh-termux-setup
dsh web
```

`dsh-termux-setup` fetches `@deepseek-ai/dsh` from the npm registry (with
npmjs→npmmirror fallback), applies the bundled patches, and drops in the
prebuilt natives. Small artifact; needs the registry at install time. Choose
this only when the ~110 MB download matters.

## What `dsh-termux-setup` does

Order matters: `npm install` inside the dsh directory runs `reify()`, which
deletes every package that is not part of dsh's dependency tree — including the
platform shims below. Everything that installs through npm therefore happens
**before** the shims are written.

1. `npm install -g --ignore-scripts @deepseek-ai/dsh@<pinned version>` (nothing compiles)
2. `npm install --no-save --package-lock=false --ignore-scripts @img/sharp-wasm32`
   (sharp's portable WebAssembly fallback — required for the attachment plugin
   to boot on android-arm64)
3. Applies the Android source patches bundled in `patches/` with `-F0`
   (no fuzzy matching); the critical ones abort the install when they fail
4. Drops in the prebuilt natives:
   - `node-pty/build/Release/pty.node`
   - `koffi/build/koffi/android_arm64/koffi.node`
   - `@deepseek-ai/node-addon-system-android-arm64` (flock shim)
   - `@vscode/ripgrep-android-arm64` (rg shim)
5. Verifies the natives load, then runs `dsh --version` as the final gate
6. Patches `dsh/lib/bin.js`'s shebang so the `dsh` bin always runs with
   `--expose-internals` (required by the HMR plugin)

Everything is idempotent — re-running the install re-applies patches and
natives (npm re-extracts `dsh` first).

## Requirements

- Termux on **arm64** (aarch64) — this package ships android-arm64 binaries
  only
- Node.js `>= 24.9.0` (that is `@deepseek-ai/dsh`'s own `engines` field)
- `patch` (`pkg install patch`) — used by the layered variant to apply the
  source patches

## Rebuilding the prebuilt packages (for maintainers)

Run on an arm64 Termux device:

```bash
# 1. get a working patched install (compiles the natives once)
bash install.sh
# 2. package the tarballs (both modes by default)
DSH_DIR="$(npm root -g)/@deepseek-ai/dsh" bash scripts/build-prebuilt.sh
#    MODES=layered | MODES=full to build only one
# 3. distribute the two tarballs however you like:
#    - attach them to a GitHub release and point the README at
#      releases/latest/download/<name>
#    - or hand them over directly: npm i -g ./dsh-termux-full.tgz
```

The natives are N-API so they keep working across `dsh` updates; only bump the
pinned `DSH_VERSION` in `install.js` (and re-validate the patches) when
`install.sh`'s patches are updated for a new dsh release.

## Notes

- The `dsh` bin (installed by `@deepseek-ai/dsh` itself, or by the vendored
  package) runs with `--expose-internals` automatically via the patched
  shebang.
- Mobile UI / search plugins are **not** installed by either variant; add them
  with `dsh plugin --profile web add ...` after first boot.
