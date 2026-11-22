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

# 图标：首次构建时生成 AppIcon.icns
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    echo "==> generate app icon"
    TMP="$(mktemp -d)"
    swift "$ROOT/scripts/make-icon.swift" "$TMP/icon-1024.png" >/dev/null
    ICONSET="$TMP/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$TMP/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d "$TMP/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
    rm -rf "$TMP"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> done: $APP"
echo "open \"$APP\""
