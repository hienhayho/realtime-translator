#!/bin/bash
# Completely removes the Translate app: the installed app bundle, the
# ~/.translate-app clone (repo + downloaded model weights + Python venv,
# can be several GB), and log files. Lists everything found before deleting
# anything, asks for confirmation once.
#
# NOT removed (can't be done from a script): microphone permission (TCC) —
# reset manually via System Settings > Privacy & Security > Microphone if
# desired. Also does not touch saved app preferences (UserDefaults) —
# harmless leftover, cleared automatically if you reinstall.
set -euo pipefail

APP_PATH="/Applications/Translate.app"
INSTALL_DIR="$HOME/.translate-app"
LOGS_DIR="$HOME/Library/Logs/Translate"

GREEN='\033[0;32m'
RESET='\033[0m'

log() { printf "\n${GREEN}=== %s ===${RESET}\n" "$1"; }

# --- 1. Stop running instance, if any --------------------------------------
log "Checking for a running instance"

if pgrep -f "$APP_PATH/Contents/MacOS/Translate" >/dev/null 2>&1; then
    echo "Translate is running — quitting it first."
    osascript -e 'tell application "Translate" to quit' 2>/dev/null || true
    sleep 2
fi

# Backend/llama-server subprocesses are owned by the app and should have
# been terminated when it quit — but clean up any orphans defensively.
pkill -f "$INSTALL_DIR/backend" 2>/dev/null || true
pkill -f "llama-server.*--port 8081" 2>/dev/null || true

# --- 2. Find what's actually there ------------------------------------------
log "Found the following"

FOUND=0
if [ -d "$APP_PATH" ]; then
    echo "  $APP_PATH"
    FOUND=1
fi
if [ -d "$INSTALL_DIR" ]; then
    SIZE="$(du -sh "$INSTALL_DIR" 2>/dev/null | cut -f1)"
    echo "  $INSTALL_DIR ($SIZE)"
    FOUND=1
fi
if [ -d "$LOGS_DIR" ]; then
    echo "  $LOGS_DIR"
    FOUND=1
fi

if [ "$FOUND" -eq 0 ]; then
    echo "Nothing to remove — Translate isn't installed."
    exit 0
fi

# --- 3. Confirm --------------------------------------------------------
echo ""
if [ -t 0 ]; then
    read -r -p "Delete all of the above? This cannot be undone. [y/N] " CONFIRM
    case "$CONFIRM" in
        y|Y|yes|YES) ;;
        *) echo "Cancelled — nothing was removed."; exit 0 ;;
    esac
else
    echo "Running non-interactively — proceeding without confirmation."
fi

# --- 4. Remove -----------------------------------------------------------
log "Removing"

if [ -d "$APP_PATH" ]; then
    rm -rf "$APP_PATH"
    echo "Removed $APP_PATH"
fi
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "Removed $INSTALL_DIR"
fi
if [ -d "$LOGS_DIR" ]; then
    rm -rf "$LOGS_DIR"
    echo "Removed $LOGS_DIR"
fi

echo ""
echo "Done. Microphone permission (if granted) is not affected by this script —"
echo "reset it manually via System Settings > Privacy & Security > Microphone"
echo "if you want that gone too."
