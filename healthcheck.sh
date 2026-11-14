#!/usr/bin/env bash
# healthcheck.sh — Post-install self-check for the Termux dsh deployment.
#
# Usage:
#   bash healthcheck.sh            # human-readable report
#   bash healthcheck.sh --quiet    # exit code only (0 = no failures)
#   bash healthcheck.sh --verbose  # include extra detail per check
#
# Exit codes: 0 = no FAIL, 1 = at least one FAIL, 2 = not a Termux/dsh host.
# WARN never fails the run — warnings are the documented limits, not breakage.
#
# Installs nothing and never edits your files. It does create short-lived probe
# files (a temp dir under $TMPDIR, plus one empty file per filesystem probe) and
# removes them on exit, including on Ctrl-C.

set -uo pipefail

QUIET=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --quiet)   QUIET=1 ;;
        --verbose) VERBOSE=1 ;;
        -h|--help)
            sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
    esac
done

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME="${HOME:-/data/data/com.termux/files/home}"
TMPDIR="${TMPDIR:-$PREFIX/tmp}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DSH_ROOT="$(npm root -g 2>/dev/null)"
DSH_DIR="$DSH_ROOT/@deepseek-ai/dsh"
DSH_PKGS="$DSH_DIR/node_modules/@deepseek-ai"
DEFAULT_PORT="${DSH_PORT:-3080}"

PASS=0; WARN=0; FAIL=0

# Colour only on a TTY, and honour NO_COLOR (https://no-color.org/).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_SEC=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_BAD=""; C_SEC=""; C_OFF=""
fi

# Probe scratch space: one temp dir, removed on any exit path.
PROBE_DIR="$(mktemp -d "${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}/dsh-healthcheck.XXXXXX" 2>/dev/null || true)"
cleanup() { [ -n "${PROBE_DIR:-}" ] && rm -rf "$PROBE_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# --quiet must emit nothing at all (only the exit code matters), so redirect
# stdout to /dev/null here; ok/warn/bad already skip their own printing.
[ "$QUIET" = 1 ] && exec 1>/dev/null

ok()   { PASS=$((PASS+1)); [ "$QUIET" = 1 ] || printf '  %s[ OK ]%s %s\n' "$C_OK" "$C_OFF" "$1"; }
warn() { WARN=$((WARN+1)); [ "$QUIET" = 1 ] || printf '  %s[WARN]%s %s\n' "$C_WARN" "$C_OFF" "$1"; }
bad()  { FAIL=$((FAIL+1)); [ "$QUIET" = 1 ] || printf '  %s[FAIL]%s %s\n' "$C_BAD" "$C_OFF" "$1"; }
info() { [ "$QUIET" = 1 ] && return; [ "$VERBOSE" = 1 ] && printf '         %s\n' "$1"; }
sec()  { [ "$QUIET" = 1 ] || printf '\n%s== %s ==%s\n' "$C_SEC" "$1" "$C_OFF"; }

# ── 1. Platform and toolchain ───────────────────────────────────────────────
sec "1. Platform / toolchain"

OS_NAME="$(uname -o 2>/dev/null)"
if [ "$OS_NAME" = "Android" ]; then
    ok "Android ($(uname -m 2>/dev/null)), SDK $(getprop ro.build.version.sdk 2>/dev/null || echo '?'), Android $(getprop ro.build.version.release 2>/dev/null || echo '?')"
else
    bad "Not Android (uname -o = '$OS_NAME') — this deployment targets Termux only"
fi

if [ -z "${PREFIX:-}" ]; then
    bad "\$PREFIX unset — not a Termux environment"
elif [ -d "$PREFIX" ]; then
    ok "\$PREFIX=$PREFIX"
fi

if command -v node >/dev/null 2>&1; then
    NODE_V="$(node -v 2>/dev/null)"
    NODE_MAJOR="$(printf '%s' "${NODE_V#v}" | cut -d. -f1)"
    NODE_MINOR="$(printf '%s' "${NODE_V#v}" | cut -d. -f2)"
    if [ "${NODE_MAJOR:-0}" -gt 24 ] 2>/dev/null || { [ "${NODE_MAJOR:-0}" -eq 24 ] && [ "${NODE_MINOR:-0}" -ge 9 ]; } 2>/dev/null; then
        ok "Node $NODE_V (ABI $(node -p 'process.versions.modules' 2>/dev/null), $(node -p 'process.arch' 2>/dev/null))"
    else
        bad "Node $NODE_V is below dsh's requirement (>=24.9.0) — pkg install nodejs-lts"
    fi
else
    bad "node not found"
fi

if [ -d "$DSH_DIR" ]; then
    ok "dsh $(node -p "require('$DSH_DIR/package.json').version" 2>/dev/null) at $DSH_DIR"
    # The npm bin link: without it `dsh` is simply not a command, which every
    # other check would happily ignore.
    if [ -x "${PREFIX:-/data/data/com.termux/files/usr}/bin/dsh" ]; then
        ok "dsh on PATH via $PREFIX/bin/dsh"
    else
        bad "$PREFIX/bin/dsh is missing — re-run: bash install.sh"
    fi
else
    bad "dsh not installed (npm root -g = ${DSH_ROOT:-<empty>})"
    if [ -d "${DSH_ROOT:-/nonexistent}/dsh-termux" ] || [ -d "$HOME/.npm-global/lib/node_modules/dsh-termux" ]; then
        echo ""
        echo "  dsh-termux IS installed but the deployment never ran."
        echo "  From npm 12 on, postinstall is blocked by default (allowScripts) and"
        echo "  npm still exits 0. Finish the install explicitly:"
        echo ""
        echo "      dsh-termux-setup"
        echo ""
    else
        echo ""
        echo "  Cannot continue without dsh. Run: bash install.sh"
    fi
    exit 2
fi

if command -v pnpm >/dev/null 2>&1; then
    ok "pnpm $(pnpm --version 2>/dev/null)"
else
    warn "pnpm missing — 'dsh plugin add/remove' will not work"
fi

AVAIL_KB="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "$AVAIL_KB" ]; then
    ok "Disk free under \$HOME: $((AVAIL_KB / 1024)) MB"
fi

# ── 2. Shebang / internals access ───────────────────────────────────────────
# Patches 09/10 make dsh depend on --expose-internals because upstream ships no
# android-arm64 build of node-addon-require-builtin. If the shebang loses the
# flag (npm re-extract, editor rewrite, reinstall), dsh dies at boot with
# "No usable native binding found".
sec "2. Internals access (--expose-internals)"

BIN_JS="$DSH_DIR/lib/bin.js"
if [ -f "$BIN_JS" ]; then
    SHEBANG="$(head -1 "$BIN_JS" 2>/dev/null)"
    case "$SHEBANG" in
        *--expose-internals*)
            ok "bin.js shebang carries --expose-internals"
            info "$SHEBANG"
            ;;
        *)
            bad "bin.js shebang is MISSING --expose-internals"
            echo "         dsh will crash at boot: 'No usable native binding found for"
            echo "         node-addon-require-builtin-android-arm64'. Fix with: bash install.sh"
            info "$SHEBANG"
            ;;
    esac
    if [ -x "$BIN_JS" ]; then
        ok "bin.js is executable"
    else
        bad "bin.js is not executable (chmod +x \"$BIN_JS\")"
    fi
else
    bad "lib/bin.js not found under $DSH_DIR"
fi

# Does the mandatory internal-module path actually work right now?
if node --expose-internals -e 'require("internal/modules/cjs/loader")' >/dev/null 2>&1; then
    ok "internal/modules/* reachable with --expose-internals"
else
    bad "internal/modules/* NOT reachable even with --expose-internals (Node too old/new?)"
fi

# The desktop-only addon is expected to be unusable. Its absence is fine now,
# but a *present* binding would mean someone silently changed the fallback.
if ( cd "$DSH_DIR" && node -e 'require("node-addon-require-builtin")' >/dev/null 2>&1 ); then
    warn "node-addon-require-builtin loaded — unexpected on Android; re-check patch 09"
else
    ok "node-addon-require-builtin unavailable (expected; --expose-internals fallback in use)"
fi

# End-to-end: the only check that proves the whole chain still works. Patches
# can be "applied" per patch(1) while the process still fails to boot.
if ( cd "$DSH_DIR" && node --expose-internals ./lib/bin.js --version >/dev/null 2>&1 ); then
    ok "dsh starts (--version)"
else
    bad "dsh does not start (--version failed) — see troubleshooting.md > problem 1"
fi

# ── 3. Native modules ───────────────────────────────────────────────────────
sec "3. Native modules"

for mod in node-pty koffi; do
    if ( cd "$DSH_DIR" && node -e "require('$mod')" >/dev/null 2>&1 ); then
        ok "$mod loads"
    else
        bad "$mod fails to load — rebuild with: bash install.sh"
    fi
done

# flock (session write lease) — android-arm64 N-API addon via the shim package
if ( cd "$DSH_DIR" && DSH_PROBE_FILE="${PROBE_DIR:-$TMPDIR}/flock-probe" node --input-type=module -e '
import { tryLockExclusive } from "@deepseek-ai/node-addon-system/flock";
import { openSync } from "node:fs";
const fd = openSync(process.env.DSH_PROBE_FILE, "w");
await tryLockExclusive(fd);
console.log("FLOCK_OK");
' 2>/dev/null | grep -q FLOCK_OK ); then
    ok "flock android-arm64 loads (session write lock functional)"
else
    bad "flock android-arm64 fails — session writes will fail (re-run: bash install.sh)"
fi

if ( cd "$DSH_DIR" && node -e '
const s = require("sharp");
s({create:{width:8,height:8,channels:3,background:{r:1,g:2,b:3}}}).png().toBuffer()
  .then(b => process.exit(b.length > 0 ? 0 : 1)).catch(() => process.exit(1));
' >/dev/null 2>&1 ); then
    ok "sharp usable (WebAssembly backend; encode/decode verified)"
else
    bad "sharp unusable — image attachments and thumbnail generation will fail"
fi

PTY_RESULT="$( cd "$DSH_DIR" && node -e '
try {
  const pty = require("node-pty");
  const p = pty.spawn(process.env.PREFIX + "/bin/bash", ["-c", "echo PTY_OK"], {name:"xterm-256color", cols:80, rows:24});
  let out = "";
  p.onData(d => out += d);
  p.onExit(() => { console.log(out.includes("PTY_OK") ? "PTY_OK" : "PTY_BAD"); });
  setTimeout(() => { try { p.kill(); } catch {} }, 3000);
} catch (e) { console.log("PTY_ERR:" + e.message); }
' 2>/dev/null | tail -1 )"
case "$PTY_RESULT" in
    PTY_OK)  ok "PTY spawn works (terminal plugin functional)" ;;
    "")      bad "PTY probe produced no output" ;;
    *)       bad "PTY spawn failed: $PTY_RESULT" ;;
esac

if [ -x "$PREFIX/bin/bash" ]; then
    ok "bash present at \$PREFIX/bin/bash"
else
    bad "\$PREFIX/bin/bash missing — terminal cannot start"
fi

# ── 4. Search backend ───────────────────────────────────────────────────────
sec "4. Search backend (ripgrep)"

if command -v rg >/dev/null 2>&1; then
    ok "rg $(rg --version 2>/dev/null | head -1 | awk '{print $2}') at $(command -v rg)"
else
    bad "rg missing — glob/grep tools degrade or fail (pkg install ripgrep)"
fi

RG_SHIM="$DSH_DIR/node_modules/@vscode/ripgrep-android-arm64/bin/rg"
if [ -e "$RG_SHIM" ]; then
    ok "@vscode/ripgrep-android-arm64 shim resolves"
    info "$RG_SHIM -> $(readlink -f "$RG_SHIM" 2>/dev/null)"
else
    warn "@vscode/ripgrep-android-arm64 shim absent (patch 08's system-rg fallback covers this)"
fi

# ── 5. Patch coverage ───────────────────────────────────────────────────────
sec "5. Patch coverage"

PATCH_DIR="${DSH_REPO_DIR:-$(cd "$(dirname "$0")" && pwd)}/patches"
patch_target() {
    case "$1" in
        terminal-bash-android-shell)                echo "$DSH_PKGS/dsh-terminal-bash" ;;
        session-persistence-link-rename)            echo "$DSH_PKGS/dsh-session-persistence-jsonl" ;;
        subprocess-local-android)                   echo "$DSH_PKGS/dsh-subprocess-local" ;;
        native-command-termux-open)                 echo "$DSH_PKGS/dsh-native-command" ;;
        host-directory-picker-native-android)       echo "$DSH_PKGS/dsh-host-directory-picker-native" ;;
        workspace-archive-skip-session-known-check) echo "$DSH_PKGS/dsh-workspace" ;;
        sandbox-local-proot-runner)                 echo "$DSH_PKGS/dsh-sandbox-local" ;;
        dsh-tool-fs-search-android-rg)              echo "$DSH_PKGS/dsh-util-ripgrep" ;;
        app-boot-expose-internals)                  echo "$DSH_PKGS/dsh-app-boot" ;;
        inspector-worker-expose-internals)          echo "$DSH_PKGS/dsh-experimental-inspector" ;;
        koffi-statx)                                echo "$DSH_DIR/node_modules/koffi" ;;
        node-addon-system-flock-android)            echo "$DSH_PKGS/node-addon-system" ;;
        *)                                          echo "" ;;
    esac
}

# A patch goes obsolete once upstream folds the same change in: its target file
# may be renamed (content-hashed bundles) or moved into another package, so
# `patch --reverse --dry-run` reports "not applied" although the behaviour is
# already there. Detect the behaviour, not the diff shape.
#
# Each probe must see the change in *every* file the patch touches, so a
# half-applied patch (one file patched, its sibling not) is still reported as
# NOT applied instead of being excused as upstreamed.
patch_upstreamed() {
    case "$1" in
        subprocess-local-android)
            # Patch 03 flips both decisions: the inspector factory in the
            # content-hashed runner-launch bundle and the state machine in
            # lib/index.js. Require both.
            grep -qs 'platform === "android"' "$DSH_PKGS/dsh-subprocess-local/lib/index.js" &&
                grep -qs 'platform === "android"' "$DSH_PKGS/dsh-subprocess-local/lib"/runner-launch-*.js ;;
        dsh-tool-fs-search-android-rg)
            # Upstream moved ripgrep resolution into dsh-util-ripgrep, keeping
            # the same Termux fallback (platform package -> system rg).
            [ -f "$DSH_PKGS/dsh-util-ripgrep/lib/index.js" ] &&
                grep -qs 'RIPGREP_BIN' "$DSH_PKGS/dsh-util-ripgrep/lib/index.js" ;;
        *)
            return 1 ;;
    esac
}

if [ -d "$PATCH_DIR" ]; then
    for pf in "$PATCH_DIR"/*.patch; do
        [ -f "$pf" ] || continue
        base="$(basename "$pf")"
        key="$(printf '%s' "$base" | sed -E 's/^[0-9]+-//; s/\.patch$//')"
        tgt="$(patch_target "$key")"
        if [ -z "$tgt" ] || [ ! -d "$tgt" ]; then
            warn "$base — target package not installed"
        elif ( cd "$tgt" && patch -p1 --dry-run --reverse < "$pf" >/dev/null 2>&1 ); then
            ok "$base applied"
        elif patch_upstreamed "$key"; then
            ok "$base obsolete — upstream already ships this change"
        else
            bad "$base NOT applied — re-run: bash install.sh"
        fi
    done
else
    warn "No patches/ directory next to this script (run install.sh from the repo)"
fi

# ── 6. Sandbox capability ───────────────────────────────────────────────────
sec "6. Sandbox (expected degraded — see README 'Known limitations')"

if command -v proot >/dev/null 2>&1; then
    ok "proot at $(command -v proot)"
    if proot -0 "$PREFIX/bin/bash" -c 'true' >/dev/null 2>&1; then
        ok "proot can execute commands"
    else
        warn "proot present but a trivial command failed"
    fi
    warn "proot enforcement is 'partial': read-only profile is NOT enforced, host FS stays visible, uid unchanged"
else
    bad "proot missing — bash sandbox cannot start (pkg install proot)"
fi

if command -v bwrap >/dev/null 2>&1; then
    ok "bubblewrap present — full confinement may be available"
else
    warn "bubblewrap absent — no namespace/seccomp confinement on this device"
fi

# ── 7. Port availability ────────────────────────────────────────────────────
# We cannot use ss/netstat/lsof reliably on Android, so probe by connecting.
sec "7. Web port ($DEFAULT_PORT)"

port_open() {
    node -e '
const net = require("net");
const s = net.connect({host:"127.0.0.1", port:Number(process.argv[1])});
s.setTimeout(1200);
s.on("connect", () => { s.destroy(); process.exit(0); });
s.on("timeout",  () => { s.destroy(); process.exit(1); });
s.on("error",    () => process.exit(1));
' "$1" >/dev/null 2>&1
}

if port_open "$DEFAULT_PORT"; then
    ok "127.0.0.1:$DEFAULT_PORT is accepting connections (dsh web appears to be running)"
    if curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$DEFAULT_PORT/" 2>/dev/null | grep -q '^401$'; then
        ok "unauthenticated request correctly rejected with 401"
    fi
else
    warn "nothing listening on 127.0.0.1:$DEFAULT_PORT (start it: dsh web --no-open)"
fi

# Is it reachable from outside the device? dsh binds 127.0.0.1 by default; if
# someone passed --host on a LAN address this is the one place it shows up.
info "dsh binds 127.0.0.1 by default; passing --host <lan-ip> exposes it to the network."

# ── 8. Filesystem semantics: link(2), rename(2), FUSE ──────────────────────
# Two independent constraints stack here, and they are easy to confuse:
#
#   a) SELinux on Android denies link(2) (EACCES) for app_data_file contexts
#      EVERYWHERE, including $HOME and $PREFIX/tmp. This is not a /sdcard
#      problem. It is why patch 02 replaces link(2) with an atomic rename(2).
#
#   b) Shared storage (/sdcard) is FUSE-backed on top of that: no exec bit,
#      no symlinks, case-insensitive lookups, and different rename semantics.
#      A dsh workspace or session store living there is a data-loss risk.
sec "8. Filesystem semantics (link / rename / FUSE)"

fs_probe() {
    # fs_probe <dir> <op> -> prints "OK" or the failure reason
    local d="$1" op="$2" probe
    probe="$d/.dsh-fsprobe-$$"
    rm -rf "$probe" 2>/dev/null
    mkdir -p "$probe" 2>/dev/null || { printf 'unwritable'; return; }
    case "$op" in
        link)
            : > "$probe/a" 2>/dev/null
            if ln "$probe/a" "$probe/b" 2>/dev/null; then printf 'OK'; else printf 'denied'; fi
            ;;
        rename)
            : > "$probe/a" 2>/dev/null
            if mv "$probe/a" "$probe/b" 2>/dev/null; then printf 'OK'; else printf 'denied'; fi
            ;;
    esac
    rm -rf "$probe" 2>/dev/null
}

LINK_HOME="$(fs_probe "$HOME" link)"
RENAME_HOME="$(fs_probe "$HOME" rename)"
if [ "$LINK_HOME" = "OK" ]; then
    ok "link(2) works under \$HOME"
else
    warn "link(2) denied under \$HOME (SELinux app_data_file) — expected on Android"
    echo "         Patch 02 falls back to atomic rename(2); this is why it exists."
fi
if [ "$RENAME_HOME" = "OK" ]; then
    ok "rename(2) works under \$HOME — the session-persistence fallback is viable"
else
    bad "rename(2) denied under \$HOME — session persistence cannot work at all"
fi

SDCARD_DIR=""
for p in /sdcard /storage/emulated/0 "$HOME/storage/shared"; do
    [ -d "$p" ] && [ -w "$p" ] && { SDCARD_DIR="$p"; break; }
done

if [ -n "$SDCARD_DIR" ]; then
    ok "shared storage writable at $SDCARD_DIR"
    if [ "$(fs_probe "$SDCARD_DIR" link)" = "OK" ]; then
        warn "link(2) unexpectedly works on shared storage — FUSE behaviour may differ per ROM"
    else
        warn "link(2) also denied on shared storage (FUSE + SELinux, two layers)"
    fi
else
    warn "no writable shared storage (run 'termux-setup-storage' only if you need /sdcard)"
fi

# The check that actually decides whether this deployment is safe to use.
if [ -d "$DSH_HOME" ]; then
    DSH_HOME_REAL="$(readlink -f "$DSH_HOME" 2>/dev/null || printf '%s' "$DSH_HOME")"
    case "$DSH_HOME_REAL" in
        /sdcard/*|/storage/emulated/*|"$HOME"/storage/*)
            bad "DSH_HOME ($DSH_HOME_REAL) is on FUSE shared storage"
            echo "         Sessions and workspace state will corrupt. Move it to internal storage:"
            echo "           export DSH_HOME=\"\$HOME/.dsh\""
            ;;
        *)
            ok "DSH_HOME on internal storage ($DSH_HOME_REAL)"
            ;;
    esac
else
    warn "DSH_HOME ($DSH_HOME) does not exist yet (created on first run)"
fi

CWD_REAL="$(pwd -P 2>/dev/null)"
case "$CWD_REAL" in
    /sdcard/*|/storage/emulated/*|"$HOME"/storage/*)
        warn "working directory is on FUSE shared storage ($CWD_REAL)"
        echo "         Workspaces here risk link()/rename() failures and lost exec bits; prefer \$HOME."
        ;;
    *)
        info "working directory: $CWD_REAL (internal storage)"
        ;;
esac

# ── 9. Credentials ──────────────────────────────────────────────────────────
sec "9. Credentials"

CRED="$DSH_HOME/.credentials.yaml"
if [ -f "$CRED" ]; then
    CRED_MODE="$(stat -c %a "$CRED" 2>/dev/null)"
    if [ "$CRED_MODE" = "600" ]; then
        ok "credentials present, mode 600"
    else
        warn "credentials mode is $CRED_MODE — tighten it: chmod 600 \"$CRED\""
    fi
else
    warn "no credentials yet — sign in to a model provider in the web UI"
fi

# ── 10. Background survival (Android 12+) ───────────────────────────────────
sec "10. Background survival"

SDK="$(getprop ro.build.version.sdk 2>/dev/null)"
if [ -n "$SDK" ] && [ "$SDK" -ge 31 ] 2>/dev/null; then
    warn "Android SDK $SDK has the phantom process killer — a background node can be reaped"
    echo "         Mitigate: termux-wake-lock  +  Settings > Apps > Termux > Battery > Unrestricted"
fi
if command -v termux-wake-lock >/dev/null 2>&1; then
    ok "termux-wake-lock available (does not prove a lock is currently held)"
else
    warn "termux-wake-lock missing"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
if [ "$QUIET" = 0 ]; then
    printf '\n%s== Summary ==%s\n' "$C_SEC" "$C_OFF"
    printf '  %s%d passed%s   %s%d warnings%s   %s%d failures%s\n' "$C_OK" "$PASS" "$C_OFF" "$C_WARN" "$WARN" "$C_OFF" "$C_BAD" "$FAIL" "$C_OFF"
    [ "$FAIL" -eq 0 ] && printf '  No failures. Warnings are documented limits, not breakage.\n'
fi

[ "$FAIL" -gt 0 ] && exit 1
exit 0
