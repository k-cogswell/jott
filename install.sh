#!/bin/bash
# ======================================================================
# JOTTBAR INSTALLER
# ======================================================================
# Builds JottBar.app from source and installs it to ~/Applications.
#
# Building locally is deliberate: macOS applies the quarantine attribute
# to DOWNLOADED apps, not compiled ones. An app built on this machine
# launches with no Gatekeeper prompt at all, which means no code signing
# certificate and no Apple Developer Program membership are required.
#
# Nothing here needs sudo.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="JottBar"
BUNDLE_ID="com.kylecogswell.jottbar"
INSTALL_DIR="$HOME/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"
CLI_PATH="$REPO_DIR/jott"

say()  { printf "\033[1;36m==>\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m warning:\033[0m %s\n" "$1"; }
die()  { printf "\033[1;31m error:\033[0m %s\n" "$1" >&2; exit 1; }

# ---------------------------------------------------------------- checks
if ! xcode-select -p >/dev/null 2>&1; then
    die "Xcode Command Line Tools are required.

  Install them with:
      xcode-select --install

  They provide both the Swift compiler and the python3 that the CLI runs on."
fi

command -v swift >/dev/null 2>&1 || die "swift not found on PATH even though the Command Line Tools are installed."
[ -f "$CLI_PATH" ] || die "Could not find the jott CLI at $CLI_PATH"

# ---------------------------------------------------------------- build
say "Building $APP_NAME (release)…"
cd "$REPO_DIR/app"
swift build -c release
BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
[ -f "$BINARY" ] || die "Build finished but no binary at $BINARY"

# ------------------------------------------------------- assemble bundle
# SwiftPM emits a bare executable, so the .app is assembled by hand. This
# keeps the Command Line Tools sufficient -- no Xcode project needed.
say "Assembling $APP_NAME.app…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/$APP_NAME.app/Contents/MacOS"
mkdir -p "$STAGE/$APP_NAME.app/Contents/Resources"
cp "$BINARY" "$STAGE/$APP_NAME.app/Contents/MacOS/$APP_NAME"
cp "$REPO_DIR/app/Resources/Info.plist" "$STAGE/$APP_NAME.app/Contents/Info.plist"

# Regenerate the icon if it is missing, then bundle it.
if [ ! -f "$REPO_DIR/app/Resources/AppIcon.icns" ]; then
    say "Generating app icon…"
    swift "$REPO_DIR/app/Resources/make-icon.swift" "$REPO_DIR/assets/logo.png" "$REPO_DIR/app/Resources" >/dev/null
fi
cp "$REPO_DIR/app/Resources/AppIcon.icns" "$STAGE/$APP_NAME.app/Contents/Resources/AppIcon.icns"

# Ad-hoc signature. Apple Silicon refuses to execute unsigned arm64 code,
# so this is required even for a purely local build. It is NOT the same as
# a Developer ID signature and does not enable distribution.
say "Signing (ad-hoc)…"
codesign --force --deep --sign - "$STAGE/$APP_NAME.app"

# ---------------------------------------------------------------- install
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    say "Quitting the running instance…"
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || pkill -x "$APP_NAME" || true
    sleep 1
fi

say "Installing to ${APP_PATH}…"
mkdir -p "$INSTALL_DIR"
rm -rf "$APP_PATH"
cp -R "$STAGE/$APP_NAME.app" "$APP_PATH"

# Point the app at this checkout's CLI so it works regardless of PATH.
say "Pointing JottBar at ${CLI_PATH}…"
defaults write "$BUNDLE_ID" cliPath -string "$CLI_PATH"

chmod +x "$CLI_PATH" 2>/dev/null || true

# ------------------------------------------------ optional: CLI on PATH
if ! command -v jott >/dev/null 2>&1; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$CLI_PATH" "$HOME/.local/bin/jott"
    say "Linked the CLI into ~/.local/bin"
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) warn "~/.local/bin is not on your PATH. To use \`jott\` in a terminal, add:
      export PATH=\"\$HOME/.local/bin:\$PATH\"
  (The menubar app works either way.)" ;;
    esac
fi

# ---------------------------------------------------------------- launch
say "Launching…"
open "$APP_PATH"

cat <<EOF

  $APP_NAME is running — look for the clock in your menu bar.

  Press ⌥⌘J from anywhere to log what you are working on.
  Change the shortcut, or turn on Launch at Login, from Settings in
  the menubar dropdown.

  To update later:   git pull && ./install.sh
  To remove:         ./uninstall.sh

EOF
