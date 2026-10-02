#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product MacNetSpeed
swiftc Scripts/MakeIcon.swift -o "$ROOT/.build/make-icon" -framework AppKit

DIST="$ROOT/dist"
ICONSET="$DIST/AppIcon.iconset"
APP="$DIST/MacNetSpeed.app"
rm -rf "$APP" "$ICONSET" "$DIST/dmg" "$DIST/MacNetSpeed.dmg"
mkdir -p "$ICONSET" "$APP/Contents/MacOS" "$APP/Contents/Resources"

"$ROOT/.build/make-icon" "$DIST/icon-1024.png"
sips -z 16 16 "$DIST/icon-1024.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$DIST/icon-1024.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$DIST/icon-1024.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$DIST/icon-1024.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$DIST/icon-1024.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$DIST/icon-1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$DIST/icon-1024.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$DIST/icon-1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$DIST/icon-1024.png" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$DIST/icon-1024.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp "$ROOT/.build/release/MacNetSpeed" "$APP/Contents/MacOS/MacNetSpeed"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

mkdir -p "$DIST/dmg"
cp -R "$APP" "$DIST/dmg/MacNetSpeed.app"
ln -s /Applications "$DIST/dmg/Applications"
hdiutil create -volname "MacNetSpeed" -srcfolder "$DIST/dmg" -ov -format UDZO "$DIST/MacNetSpeed.dmg" >/dev/null

echo "Built $APP"
echo "Built $DIST/MacNetSpeed.dmg"
