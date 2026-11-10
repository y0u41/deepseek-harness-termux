#!/usr/bin/env bash
# build-prebuilt.sh — assemble the dsh-termux prebuilt tarballs (Plan B).
#
# Run on an arm64 Termux device that already has a WORKING patched install
# (run install.sh once). Produces two tarballs:
#   dsh-termux.tgz        (layered,  ~360 KB) — small; postinstall pulls dsh
#                          from the npm registry (with npmjs→npmmirror fallback)
#   dsh-termux-full.tgz   (vendored, ~55 MB)  — fully offline; bundles the
#                          entire patched dsh + node_modules incl. natives
#
# Install them on another arm64 device with:
#   npm i -g ./dsh-termux-full.tgz                  # self-contained
#   npm i -g ./dsh-termux.tgz && dsh-termux-setup   # small, pulls dsh from npm
#
# To distribute via a GitHub release, attach both tarballs and point the README
# at releases/latest/download/<name>. Both must be in the SAME release, and the
# release must not be a pre-release, or releases/latest will not resolve.
#
# Usage:
#   bash scripts/build-prebuilt.sh                 # uses the global install
#   DSH_DIR=/path/to/dsh bash scripts/build-prebuilt.sh
#   MODES=layered bash scripts/build-prebuilt.sh   # only the layered tarball
#   MODES=full   bash scripts/build-prebuilt.sh    # only the vendored tarball
#
# The natives are N-API (ABI stable), so the tarballs keep working across dsh
# updates; rebuild only when the patches or native deps change.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$REPO_DIR/prebuilt"
MODES="${MODES:-layered full}"
# Release version for BOTH tarballs. One product, one version — the previous
# build stamped the layered package 0.2.2-termux.1 but the vendored one
# 0.2.2-rc.1-termux.1, so two artifacts of the same release disagreed.
REL_VERSION="${REL_VERSION:-$(node -p "require('$PKG_DIR/package.json').version")}"
# Must be exported: the vendored package.json rewrite below happens in a node
# child process. Un-exported, j.version became undefined and JSON.stringify()
# silently dropped the field, producing a tarball npm refuses to install.
export REL_VERSION

# The natives and the NDK layout are arm64/Android only: building anywhere else
# would produce an artifact labelled android-arm64 that cannot load.
if [ "$(uname -m 2>/dev/null)" != "aarch64" ]; then
    echo "[ERROR] build-prebuilt.sh must run on aarch64 (found $(uname -m 2>/dev/null))"
    exit 1
fi
if [ "$(node -p 'process.platform')" != "android" ]; then
    echo "[ERROR] build-prebuilt.sh must run on Termux/Android (found $(node -p 'process.platform'))"
    exit 1
fi

# Always clean the staging trees, including on Ctrl-C.
_STAGES=""
cleanup_stages() {
    for d in $_STAGES; do [ -n "$d" ] && rm -rf "$d"; done
}
trap cleanup_stages EXIT INT TERM
# Android's linker namespace only permits /data, /system, /apex... — anything
# staged under /tmp cannot dlopen a .node file, so the native verification below
# would fail with "is not accessible for the namespace" on a perfectly good
# build. Stage under $HOME (always on /data) and never trust TMPDIR here.
STAGE_ROOT="${HOME:?}/.dsh-build-stage"
mkdir -p "$STAGE_ROOT"
new_stage() {
    STAGE="$(mktemp -d "$STAGE_ROOT/build.XXXXXX")"
    _STAGES="$_STAGES $STAGE"
}

# ── 1. Locate a working patched install ─────────────────────────────────────
if [ -z "${DSH_DIR:-}" ]; then
    DSH_DIR="$(npm root -g)/@deepseek-ai/dsh"
fi
if [ ! -f "$DSH_DIR/package.json" ]; then
    echo "[ERROR] no @deepseek-ai/dsh found at $DSH_DIR"
    echo "        Run install.sh first, or set DSH_DIR=/path/to/dsh"
    exit 1
fi
echo "==> Using patched install at: $DSH_DIR"

PTY="$DSH_DIR/node_modules/node-pty/build/Release/pty.node"
KOFFI="$DSH_DIR/node_modules/koffi/build/koffi/android_arm64/koffi.node"
FLOCK_NODE="$DSH_DIR/node_modules/@deepseek-ai/node-addon-system-android-arm64/bin/system.node"
if [ ! -f "$PTY" ]; then
    echo "[ERROR] missing $PTY — run install.sh first"
    exit 1
fi
if [ ! -f "$KOFFI" ]; then
    echo "[ERROR] missing $KOFFI — run install.sh first"
    exit 1
fi
if [ ! -f "$FLOCK_NODE" ]; then
    echo "[ERROR] missing $FLOCK_NODE — run install.sh first"
    exit 1
fi
echo "    pty.node  : $PTY"
echo "    koffi     : $KOFFI"
echo "    flock .so : $FLOCK_NODE"

# ── 2. Sanity-check the natives load in this node ───────────────────────────
echo "==> Verifying natives load..."
if ! (cd "$DSH_DIR" && node -e "require('node-pty'); require('koffi'); console.log('    natives OK')"); then
    echo "[ERROR] natives failed to load — rebuild them first (bash install.sh)"
    exit 1
fi

# ── 3a. Layered tarball (small; dsh fetched from the registry at install) ───
build_layered() {
    echo "==> Building layered tarball (dsh-termux.tgz)..."
    new_stage
    mkdir -p "$STAGE/package/bin" \
             "$STAGE/package/patches" \
             "$STAGE/package/prebuilt/android-arm64"

    cp "$PKG_DIR/package.json" "$STAGE/package/"
    cp "$PKG_DIR/install.js"    "$STAGE/package/"
    cp "$PKG_DIR/README.md"     "$STAGE/package/"
    cp "$PKG_DIR/README.zh-CN.md" "$STAGE/package/"
    cp "$PKG_DIR/bin/dsh"       "$STAGE/package/bin/dsh"
    cp "$PKG_DIR/bin/setup.js"  "$STAGE/package/bin/setup.js"
    chmod +x "$STAGE/package/bin/dsh" "$STAGE/package/bin/setup.js"
    cp "$REPO_DIR"/patches/*.patch "$STAGE/package/patches/"
    cp "$PTY"  "$STAGE/package/prebuilt/android-arm64/pty.node"
    cp "$KOFFI" "$STAGE/package/prebuilt/android-arm64/koffi.node"
    cp "$FLOCK_NODE" "$STAGE/package/prebuilt/android-arm64/system.node"

    OUT="$REPO_DIR/dsh-termux.tgz"
    tar -czf "$OUT" -C "$STAGE" package
    rm -rf "$STAGE"
    echo "    -> $OUT ($(du -h "$OUT" | cut -f1))"
}

# ── 3b. Vendored tarball (full offline; whole patched dsh + node_modules) ───
build_full() {
    echo "==> Building vendored tarball (dsh-termux-full.tgz)..."
    new_stage
    FULL_PKG="$STAGE/package"
    mkdir -p "$FULL_PKG"

    # the whole patched install (lib, config, node_modules incl. natives)
    cp -a "$DSH_DIR/." "$FULL_PKG/"

    # node-pty's install script (prebuild.js) exits 0 only when
    # prebuilds/<platform>-<arch>/ exists — otherwise npm falls back to
    # node-gyp rebuild and tries to COMPILE. Mirror the binary there so a
    # plain `npm i -g` (no --ignore-scripts) never compiles.
    if [ -f "$DSH_DIR/node_modules/node-pty/build/Release/pty.node" ]; then
        mkdir -p "$FULL_PKG/node_modules/node-pty/prebuilds/android-arm64"
        cp "$DSH_DIR/node_modules/node-pty/build/Release/pty.node" \
           "$FULL_PKG/node_modules/node-pty/prebuilds/android-arm64/pty.node"
        chmod 755 "$FULL_PKG/node_modules/node-pty/prebuilds/android-arm64/pty.node"
        echo "    -> node-pty prebuild mirrored (prebuilds/android-arm64/pty.node)"
    fi

    # sharp's wasm fallback must live INSIDE the vendored tree (the layered
    # install drops it at the global root; here it must travel with the package)
    if [ ! -d "$FULL_PKG/node_modules/@img/sharp-wasm32" ]; then
        # install.sh puts it inside the dsh tree; the layered prebuilt puts it
        # at the global root — prefer a local copy before falling back to npm
        if [ -d "$DSH_DIR/node_modules/@img/sharp-wasm32" ]; then
            mkdir -p "$FULL_PKG/node_modules/@img"
            cp -a "$DSH_DIR/node_modules/@img/sharp-wasm32" "$FULL_PKG/node_modules/@img/"
        elif [ -d "$(dirname "$(dirname "$DSH_DIR")")/@img/sharp-wasm32" ]; then
            # dshDir = <globalRoot>/@deepseek-ai/dsh, so @img lives at <globalRoot>/@img
            mkdir -p "$FULL_PKG/node_modules/@img"
            cp -a "$(dirname "$(dirname "$DSH_DIR")")/@img/sharp-wasm32" "$FULL_PKG/node_modules/@img/"
        else
            echo "    -> fetching @img/sharp-wasm32 into the vendored tree..."
            (cd "$FULL_PKG" && env -u npm_config_prefix -u npm_config_global \
                npm install @img/sharp-wasm32 --no-save --ignore-scripts > /dev/null 2>&1 || true)
        fi
    fi

    # verify the vendored tree is self-sufficient
    export PROBE_FILE="${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}/dsh-vendored-flock-$$"
    if ! (cd "$FULL_PKG" && node -e "require('sharp'); require('node-pty'); require('koffi'); console.log('    vendored natives OK')") \
        || ! (cd "$FULL_PKG" && node --input-type=module -e 'import { tryLockExclusive } from "@deepseek-ai/node-addon-system/flock"; import { openSync } from "node:fs"; const fd = openSync(process.env.PROBE_FILE, "w"); await tryLockExclusive(fd); console.log("    vendored flock OK")'); then
        echo "[ERROR] vendored tree fails to load — aborting full build"
        rm -f "$PROBE_FILE"
        return 1
    fi
    rm -f "$PROBE_FILE"

    # rename + version suffix + bin + bundledDependencies (npm keeps the
    # bundled node_modules without re-fetching — same as the reference package)
    node -e "
        const fs = require('fs');
        const p = '$FULL_PKG/package.json';
        const j = JSON.parse(fs.readFileSync(p, 'utf8'));
        j.name = 'dsh-termux';
        if (!process.env.REL_VERSION) throw new Error('REL_VERSION is not exported');
        j.version = process.env.REL_VERSION;
        j.bin = { dsh: 'lib/bin.js', 'dsh-termux': 'lib/bin.js' };
        j.bundleDependencies = Object.keys(j.dependencies || {});
        j.description = (j.description || '') + ' (vendored Termux build)';
        fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\n');
    "

    # ensure bin.js runs with --expose-internals (HMR)
    BIN_JS="$FULL_PKG/lib/bin.js"
    if [ -f "$BIN_JS" ] && ! head -1 "$BIN_JS" | grep -q -- "--expose-internals"; then
        NODE_BIN="$(command -v node)"
        { printf '#!%s --expose-internals\n' "$NODE_BIN"; tail -n +2 "$BIN_JS"; } > "$BIN_JS.new"
        mv "$BIN_JS.new" "$BIN_JS"
        chmod +x "$BIN_JS"   # the .new rewrite drops +x under umask — restore it
        echo "    -> bin.js shebang patched (--expose-internals)"
    fi

    OUT="$REPO_DIR/dsh-termux-full.tgz"
    tar -czf "$OUT" -C "$STAGE" package
    rm -rf "$STAGE"
    echo "    -> $OUT ($(du -h "$OUT" | cut -f1))"
}

for mode in $MODES; do
    case "$mode" in
        layered) build_layered ;;
        full)    build_full ;;
        *) echo "[ERROR] unknown mode: $mode (expected: layered, full)" >&2; exit 2 ;;
    esac
done

echo ""
echo "==> Done. Built:"
echo "    $REPO_DIR/dsh-termux.tgz"
echo "    $REPO_DIR/dsh-termux-full.tgz"
echo ""
echo "    Install on another arm64 device:"
echo "      npm i -g ./dsh-termux-full.tgz                  # self-contained"
echo "      npm i -g ./dsh-termux.tgz && dsh-termux-setup   # small, needs npm registry"
echo ""
echo "    To publish: attach BOTH files to one GitHub release (not a pre-release,"
echo "    or releases/latest will not resolve), then update the README URLs."
