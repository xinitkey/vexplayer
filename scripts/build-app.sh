#!/bin/bash
# Builds build/VexPlayer.app (ad-hoc signed). Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
# Release builds keep the checkout path out of compiled-in file names (asserts in the bundled C libraries).
FLAGS=()
if [ "$CONFIG" = release ]; then
  ROOT="$(pwd)"
  FLAGS=(-Xswiftc -file-prefix-map -Xswiftc "$ROOT=." -Xcc "-ffile-prefix-map=$ROOT=.")
fi
swift build -c "$CONFIG" --product VexPlayer ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" --show-bin-path ${FLAGS[@]+"${FLAGS[@]}"})"

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/AppIcon.iconset >/dev/null
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

APP=build/VexPlayer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VexPlayer" "$APP/Contents/MacOS/VexPlayer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/VexIME.apk "$APP/Contents/Resources/VexIME.apk"
# Interface translations live in the app bundle itself, where SwiftUI and String(localized:) look them up.
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
for bundle in "$BIN"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

codesign --force --sign - "$APP"
echo "Built $APP"
