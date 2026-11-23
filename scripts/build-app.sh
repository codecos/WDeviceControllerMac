#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
APP_NAME="WDeviceController"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/WDeviceControllerMac"
if [ ! -f "$BIN_PATH" ]; then
    echo "binary not found: $BIN_PATH" >&2
    exit 1
fi

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/WDeviceControllerMac"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# 图标：画法变了（脚本比 icns 新）就重新生成
ICON_SRC="$ROOT/scripts/make-icon.swift"
if [ ! -f "$ROOT/Resources/AppIcon.icns" ] || [ "$ICON_SRC" -nt "$ROOT/Resources/AppIcon.icns" ]; then
    echo "==> generate app icon"
    swift "$ICON_SRC" --icns "$ROOT/Resources/AppIcon.icns" >/dev/null
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> done: $APP"
echo "open \"$APP\""
