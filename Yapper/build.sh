#!/usr/bin/env bash
# Build Yapper in release mode and wrap into a .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME=Yapper
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

echo "→ codesign with stable local identity"
# Self-signed "Yapper Local" cert keeps the designated requirement stable
# across rebuilds, so macOS Accessibility grants survive. Falls back to ad-hoc
# if the cert isn't present in the login keychain.
SIGN_IDENTITY="Yapper Local"
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "  (warning: '$SIGN_IDENTITY' cert not found, falling back to ad-hoc — Accessibility grant will reset on next rebuild)"
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "✅ built $APP_DIR"
echo "Run with: open $APP_DIR"
