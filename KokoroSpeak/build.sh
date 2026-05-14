#!/usr/bin/env bash
# Build KokoroSpeak in release mode and wrap into a .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME=KokoroSpeak
APP_DIR="./${APP_NAME}.app"
CONFIG=release

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
test -x "$BIN_PATH" || { echo "binary not found at $BIN_PATH"; exit 1; }

echo "→ assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_DIR/Contents/Info.plist"

echo "→ ad-hoc codesign"
codesign --force --deep --sign - "$APP_DIR"

echo "✅ built $APP_DIR"
echo "Run with: open $APP_DIR"
