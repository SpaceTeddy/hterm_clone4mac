#!/bin/bash
# Baut Hardterm für Apple Silicon und erzeugt build/Hardterm.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Hardterm"

APP="build/Hardterm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hardterm"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sprachdateien (Deutsch, Englisch, Französisch, Spanisch, Italienisch)
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Fertig: $APP"
echo "Starten mit: open $APP"
