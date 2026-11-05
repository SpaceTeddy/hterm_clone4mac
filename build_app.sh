#!/bin/bash
# Baut Hardterm für Apple Silicon und erzeugt build/Hardterm.app
set -euo pipefail
cd "$(dirname "$0")"

# Version: HARDTERM_VERSION (z. B. aus CI) > letzter Git-Tag vX.Y.Z > Wert aus Info.plist
VERSION="${HARDTERM_VERSION:-}"
if [ -z "$VERSION" ]; then
    TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
    VERSION="${TAG#v}"
fi
[ -n "$VERSION" ] || VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
# Build-Nummer: Anzahl der Commits (fortlaufend), ohne Git 1
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Hardterm"

APP="build/Hardterm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hardterm"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
# Sprachdateien (Deutsch, Englisch, Französisch, Spanisch, Italienisch)
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Fertig: $APP (Version $VERSION, Build $BUILD)"
echo "Starten mit: open $APP"
