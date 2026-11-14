#!/usr/bin/env bash
# Re-apply the Termux (android-arm64) ripgrep fix for DSH's glob/grep tools.
#
# Why: @vscode/ripgrep resolves its platform package as
#   @vscode/ripgrep-${process.platform}-${process.arch}
# which on Termux is @vscode/ripgrep-android-arm64 — a package that does not
# exist. Its module evaluation throws "Could not find @vscode/ripgrep-android-
# arm64", so both dsh tools fail with "ripgrep launch failed".
#
# Part 1: shim package @vscode/ripgrep-android-arm64 whose bin/rg symlinks the
#   working system ripgrep (needed by fresh processes / after restart).
# Part 2: apply patches/08-dsh-tool-fs-search-android-rg.patch so
#   resolveRgPath() resolves via require.resolve() (pure filesystem
#   resolution, no module evaluation) with a system-rg fallback — this also
#   bypasses Node's cached-errored @vscode/ripgrep ESM module in the live
#   server process.
# Then hot-reload the plugin: dev_reload_package "dsh-util-ripgrep".
#
# Idempotent. Run it after `npm update -g @deepseek-ai/dsh` if glob/grep break.
set -euo pipefail

# Prefer the actual npm global root so this works with the standard Termux
# `npm root -g` location as well as a custom prefix.
if [ -z "${DSH_ROOT:-}" ]; then
  if _g="$(npm root -g 2>/dev/null)" && [ -n "$_g" ]; then
    DSH_ROOT="$_g/@deepseek-ai/dsh"
  else
    DSH_ROOT="/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh"
  fi
fi
RG_SYSTEM="${RG_SYSTEM:-/data/data/com.termux/files/usr/bin/rg}"

[ -x "$RG_SYSTEM" ] || { echo "system rg not found at $RG_SYSTEM" >&2; exit 1; }
# Only require the top-level node_modules: Part 1 creates node_modules/@vscode itself.
[ -d "$DSH_ROOT/node_modules" ] || { echo "DSH node_modules not found: $DSH_ROOT" >&2; exit 1; }

# ---- Part 1: platform-package shim -------------------------------------------
SHIM="$DSH_ROOT/node_modules/@vscode/ripgrep-android-arm64"
mkdir -p "$SHIM/bin"
cat > "$SHIM/package.json" <<'EOF'
{
  "name": "@vscode/ripgrep-android-arm64",
  "version": "1.18.0",
  "description": "Termux shim: resolves rgPath to the system ripgrep (/data/data/com.termux/files/usr/bin/rg); @vscode/ripgrep has no android platform package.",
  "license": "MIT",
  "bin": { "rg": "bin/rg" }
}
EOF
ln -sf "$RG_SYSTEM" "$SHIM/bin/rg"
echo "[1/2] shim ok: $SHIM/bin/rg -> $RG_SYSTEM"

# ---- Part 2: apply the rg patch (context generated for the current dsh) -----
PLUGIN_DIR="$DSH_ROOT/node_modules/@deepseek-ai/dsh-util-ripgrep"
[ -d "$PLUGIN_DIR" ] || { echo "plugin not found: $PLUGIN_DIR" >&2; exit 1; }
PATCH="$(cd "$(dirname "$0")" && pwd)/../patches/08-dsh-tool-fs-search-android-rg.patch"
[ -f "$PATCH" ] || { echo "patch file not found: $PATCH" >&2; exit 1; }
if (cd "$PLUGIN_DIR" && patch -p1 --dry-run --forward < "$PATCH" > /dev/null 2>&1); then
  (cd "$PLUGIN_DIR" && patch -p1 --forward < "$PATCH")
  echo "[2/2] plugin patched"
else
  echo "[2/2] plugin already patched or patch inapplicable (dsh version changed?)"
fi

node --check "$PLUGIN_DIR/lib/index.js"
echo "done. Apply to the live process (unless this just ran through the injector):"
echo "  dev_reload_package \"dsh-util-ripgrep\""
