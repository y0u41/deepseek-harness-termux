#!/usr/bin/env bash
# uninstall.sh — remove the dsh install created by install.sh / Plan B.
#
# What this removes:
#   - the global npm package @deepseek-ai/dsh (and dsh-termux, if Plan B)
#   - the `alias dsh=...` lines install.sh appended to your shell rc
#   - with --purge: $DSH_HOME (~/.dsh) — profiles, credentials, session history
#
# What this never touches:
#   - any Termux package (nodejs-lts, clang, proot, ...)
#   - your shell rc files beyond the two alias lines install.sh added
#
# Usage:
#   bash uninstall.sh              # remove dsh, keep ~/.dsh
#   bash uninstall.sh --purge      # also delete ~/.dsh (asks first)
#   bash uninstall.sh --dry-run    # print what would be removed
#   bash uninstall.sh -y           # do not ask for confirmation

set -euo pipefail

PURGE=0
DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --purge)   PURGE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -y|--yes)  ASSUME_YES=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
run()  {
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  [dry-run] $*"
    else
        "$@"
    fi
}

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    printf '%s [y/N] ' "$1"
    read -r answer
    case "$answer" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
GLOBAL_ROOT="$(npm root -g 2>/dev/null || echo "${PREFIX:-/data/data/com.termux/files/usr}/lib/node_modules")"
DSH_DIR="$GLOBAL_ROOT/@deepseek-ai/dsh"

say "==> dsh uninstall"
say "    global root: $GLOBAL_ROOT"
say "    DSH_HOME:    $DSH_HOME_DIR"
[ "$DRY_RUN" -eq 1 ] && say "    (dry-run: nothing will be deleted)"
say ""

# ── 1. Shell alias lines added by install.sh ────────────────────────────────
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    if grep -q '^alias dsh=' "$rc" 2>/dev/null; then
        say "  removing dsh alias from $rc"
        if [ "$DRY_RUN" -eq 1 ]; then
            say "  [dry-run] sed -i '/^alias dsh=/d' $rc"
        else
            # Portable in-place edit (Termux sed supports -i; keep a backup).
            cp "$rc" "$rc.dsh-uninstall.bak"
            sed -i '/^alias dsh=/d' "$rc"
            say "    (backup: $rc.dsh-uninstall.bak)"
        fi
    fi
done

# ── 2. Global npm packages ──────────────────────────────────────────────────
if [ -d "$DSH_DIR" ]; then
    say "  removing @deepseek-ai/dsh"
    run npm uninstall -g @deepseek-ai/dsh > /dev/null 2>&1 || say "  [WARN] npm uninstall failed — remove manually: $DSH_DIR"
else
    say "  @deepseek-ai/dsh not installed — nothing to remove"
fi

if [ -d "$GLOBAL_ROOT/dsh-termux" ]; then
    say "  removing dsh-termux (Plan B package)"
    run npm uninstall -g dsh-termux > /dev/null 2>&1 || say "  [WARN] npm uninstall failed — remove manually: $GLOBAL_ROOT/dsh-termux"
fi

# ── 3. DSH_HOME (optional) ──────────────────────────────────────────────────
if [ "$PURGE" -eq 1 ] && [ -d "$DSH_HOME_DIR" ]; then
    say ""
    say "  --purge: $DSH_HOME_DIR contains profiles, credentials and session history."
    if confirm "  Delete $DSH_HOME_DIR permanently?"; then
        run rm -rf "$DSH_HOME_DIR"
        say "  [OK] removed $DSH_HOME_DIR"
    else
        say "  [SKIP] kept $DSH_HOME_DIR"
    fi
elif [ -d "$DSH_HOME_DIR" ]; then
    say ""
    say "  kept $DSH_HOME_DIR (profiles, credentials, sessions). Re-run with --purge to delete."
fi

say ""
say "==> Done. Open a new shell for the alias change to take effect."
