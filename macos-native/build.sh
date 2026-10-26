#!/bin/zsh
# Builds Purgo.app and installs it in ~/Applications.
set -e
cd "$(dirname "$0")"

echo "→ Compilation (release)…"
swift build -c release

APP="build/Purgo.app"
mkdir -p build
[ -d "$APP" ] && mv "$APP" "build/.old-$(date +%s).app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Purgo "$APP/Contents/MacOS/Purgo"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  echo "→ Icône…"
  swift Resources/make_icon.swift build/icon_1024.png
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signature locale…"
codesign --force --deep -s - "$APP"

mkdir -p ~/Applications
[ -d ~/Applications/Purgo.app ] && mv ~/Applications/Purgo.app ~/.Trash/Purgo-$(date +%s).app
cp -R "$APP" ~/Applications/Purgo.app
echo "✓ Purgo installé dans ~/Applications/Purgo.app"
