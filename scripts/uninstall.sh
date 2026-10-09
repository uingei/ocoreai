#!/bin/bash
# uninstall.sh — remove ocoreai's footprint from this Mac.
#
# First principles: an installer's contract is unfinished until there is an
# honest removal story. Every path below is verified against BOTH source
# (HEAD 5fe6133) and the live machine (2026-10) — the first draft of this
# script missed SQLiteStore/lock/kvcache and the real model root; a removal
# tool that misstates the footprint is itself a lie, so paths live-checked.
#
# TIER regeneratable (app recreates; safe):
#   ~/Library/Application Support/ocoreai/cache/   kvcache (SessionPool.swift:171)
#   ~/Library/Application Support/ocoreai/logs/    crash logs (GlobalCrashHandler.swift:117)
#   ~/Library/Caches/ocoreai/                      search/preview caches (ModelStore.swift:26)
#   ~/Library/Caches/com.ocoreai.ocoreai/         URLCache (system-managed)
#   defaults domain com.ocoreai.ocoreai           GUI settings (SettingsStore.swift:400)
#
# TIER user-data (the user's; kept unless asked):
#   ~/.ocoreai/models/            weights — PRIMARY root ($OCOREAI_MODELS_DIR
#                                 override, ModelStore.swift:56; 3.3G live here)
#   ~/.ocoreai/config.yaml       authored approval policy (SettingsStore.swift:340)
#   ~/.ocoreai/backups/          config backups
#   ~/Library/Application Support/ocoreai/data/   sessions sqlite (SQLiteStore.swift:158)
#   legacy: ~/Library/Application Support/ocoreai/{models,huggingface,modelscope}
#           (ModelStore.legacyRoot — discovered, rarely written)
#
# TIER app: /Applications/ocoreai.app
# Lockfile ~/Library/Application Support/ocoreai.lock (SingleInstanceLock.swift:59)
# is flock-kernel-owned; swept with the store dir.
#
# NO keychain entries exist — tokens are env-first by design
# (SettingsStore.swift:494/510, mirroring mlx-swift-lm/coreai-models).
# This script does NOT claim to clear a keychain it never wrote.
#
# Usage:
#   scripts/uninstall.sh              # dry run: tiers + sizes, deletes nothing
#   scripts/uninstall.sh --data     # regeneratable tier
#   scripts/uninstall.sh --userdata # user-data tier (sessions, config, weights)
#   scripts/uninstall.sh --models   # ~/.ocoreai/models weights only
#   scripts/uninstall.sh --app      # /Applications/ocoreai.app
#   scripts/uninstall.sh --all      # every tier
set -euo pipefail

APPSUPPORT="$HOME/Library/Application Support/ocoreai"
DOT="$HOME/.ocoreai"
DEFAULTS_DOMAIN="com.ocoreai.ocoreai"
APP_BUNDLE="/Applications/ocoreai.app"

DATA=0 USERDATA=0 MODELS=0 APP=0
for arg in "$@"; do
    case "$arg" in
        --data) DATA=1 ;;
        --userdata) USERDATA=1 ;;
        --models) USERDATA=1; MODELS=1 ;;
        --app) APP=1 ;;
        --all) DATA=1; USERDATA=1; MODELS=1; APP=1 ;;
        -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
        *) echo "unknown flag: $arg (see: scripts/uninstall.sh -h)" >&2; exit 2 ;;
    esac
done

size_mb() { echo $(( $(du -sk "$1" 2>/dev/null | cut -f1 || echo 0) / 1024 )); }

# Collect existing items per tier into globals T_DATA/T_USER/T_MODELS.
T_DATA=() T_USER=() T_MODELS=()
exists() { [ -e "$1" ]; }
defaults_present() {
    # File-based check — `defaults domains` IPC can stall behind cfprefsd;
    # the plist on disk is ground truth anyway.
    [ -f "$HOME/Library/Preferences/$DEFAULTS_DOMAIN.plist" ]
}
exists "$APPSUPPORT/cache" && T_DATA+=("$APPSUPPORT/cache")
exists "$APPSUPPORT/logs" && T_DATA+=("$APPSUPPORT/logs")
exists "$HOME/Library/Caches/ocoreai" && T_DATA+=("$HOME/Library/Caches/ocoreai")
exists "$HOME/Library/Caches/com.ocoreai.ocoreai" && T_DATA+=("$HOME/Library/Caches/com.ocoreai.ocoreai")
defaults_present && T_DATA+=("defaults:$DEFAULTS_DOMAIN")
exists "$DOT/config.yaml" && T_USER+=("$DOT/config.yaml")
exists "$DOT/backups" && T_USER+=("$DOT/backups")
exists "$APPSUPPORT/data" && T_USER+=("$APPSUPPORT/data")
exists "$APPSUPPORT/models" && T_USER+=("$APPSUPPORT/models")
exists "$APPSUPPORT/huggingface" && T_USER+=("$APPSUPPORT/huggingface")
exists "$APPSUPPORT/modelscope" && T_USER+=("$APPSUPPORT/modelscope")
exists "$HOME/.cache/ocoreai" && T_USER+=("$HOME/.cache/ocoreai")
exists "$DOT/models" && T_MODELS+=("$DOT/models")

print_tier() { # label, items...
    local label="$1"; shift
    [ $# -eq 0 ] && return 0
    echo "[$label]"
    local t
    for t in "$@"; do
        if [[ "$t" == defaults:* ]]; then
            echo "  - ${t#defaults:} (defaults domain)"
        else
            printf "  - %s (%s MB)\n" "$t" "$(size_mb "$t")"
        fi
    done
}

echo "ocoreai uninstall plan:"
print_tier "regeneratable" ${T_DATA[@]+"${T_DATA[@]}"}
print_tier "user-data (sessions/config)" ${T_USER[@]+"${T_USER[@]}"}
print_tier "weights" ${T_MODELS[@]+"${T_MODELS[@]}"}
echo "[app]"
if [ -d "$APP_BUNDLE" ]; then
    printf "  - %s (%s MB)\n" "$APP_BUNDLE" "$(size_mb "$APP_BUNDLE")"
else
    echo "  - (not installed)"
fi

if [ $DATA -eq 0 ] && [ $USERDATA -eq 0 ] && [ $MODELS -eq 0 ] && [ $APP -eq 0 ]; then
    echo ""
    echo "DRY RUN — nothing deleted. Flags: --data | --userdata | --models | --app | --all"
    exit 0
fi

echo ""
read -r -p "Proceed with selected tiers? [y/N] " reply
[ "$reply" = "y" ] || { echo "aborted"; exit 1; }

remove_items() {
    local t
    for t in "$@"; do
        if [[ "$t" == defaults:* ]]; then
            defaults delete "${t#defaults:}" 2>/dev/null || true
            echo "  removed defaults ${t#defaults:}"
        else
            rm -rf "$t" && echo "  removed $t"
        fi
    done
}

[ $DATA -eq 1 ] && remove_items ${T_DATA[@]+"${T_DATA[@]}"}
[ $USERDATA -eq 1 ] && remove_items ${T_USER[@]+"${T_USER[@]}"}
[ $MODELS -eq 1 ] && remove_items ${T_MODELS[@]+"${T_MODELS[@]}"}
if [ $APP -eq 1 ] && [ -d "$APP_BUNDLE" ]; then
    if [ -w /Applications ]; then
        rm -rf "$APP_BUNDLE" && echo "  removed $APP_BUNDLE"
    else
        sudo rm -rf "$APP_BUNDLE" && echo "  removed $APP_BUNDLE (sudo)"
    fi
fi
# Tidy: sweep dot-dir if models removal emptied it.
[ $MODELS -eq 1 ] && rmdir "$DOT" 2>/dev/null || true

echo "done. (No keychain entries exist by design — env-first tokens,"
echo "mirroring mlx-swift-lm/coreai-models: nothing there to clear.)"
