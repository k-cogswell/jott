#!/bin/bash
# ======================================================================
# JOTTBAR UNINSTALLER
# ======================================================================
# Backing out should be as easy as trying it. Removes the app, its
# preferences, and the login item registration. Your markdown logs are
# left alone unless you pass --purge.
set -euo pipefail

APP_NAME="JottBar"
BUNDLE_ID="com.kylecogswell.jottbar"
APP_PATH="$HOME/Applications/$APP_NAME.app"

say() { printf "\033[1;36m==>\033[0m %s\n" "$1"; }

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    say "Quitting $APP_NAME…"
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || pkill -x "$APP_NAME" || true
    sleep 1
fi

# Unregister the login item before the bundle disappears, or macOS keeps
# a dangling entry in System Settings > General > Login Items.
if [ -d "$APP_PATH" ]; then
    say "Removing login item…"
    /usr/bin/osascript -e 'tell application "System Events" to delete every login item whose name is "JottBar"' 2>/dev/null || true
    say "Removing $APP_PATH…"
    rm -rf "$APP_PATH"
fi

say "Clearing preferences…"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

if [ -L "$HOME/.local/bin/jott" ]; then
    say "Removing the ~/.local/bin/jott symlink…"
    rm -f "$HOME/.local/bin/jott"
fi

if [ "$PURGE" -eq 1 ]; then
    LOG_DIR="$HOME/.jott"
    say "Purging logs and config…"
    rm -rf "$LOG_DIR" "$HOME/.config/jott"
    printf "  Removed %s and ~/.config/jott\n" "$LOG_DIR"
else
    printf "\n  Your time logs are untouched. Run with --purge to delete them too.\n"
fi

printf "\n  Done.\n\n"
