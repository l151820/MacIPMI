#!/bin/bash
# Baut MacIPMI.app (Release) nach build/MacIPMI.app – funktioniert auch nur mit den Command Line Tools.
#
# Umgebungsvariablen:
#   UNIVERSAL=1   Universal-Binary (arm64 + x86_64); benötigt Xcode
#   VERSION=1.2.3 Versionsnummer für Info.plist (Standard: aus Resources/Info.plist)
#   BUILD=42      Build-Nummer für Info.plist
set -euo pipefail
cd "$(dirname "$0")/.."

# Ab dem macOS-27-SDK ist SwiftUIs @State ein Makro, dessen Plugin nur mit Xcode ausgeliefert wird.
# Ohne Xcode bauen wir daher gegen das 26.x-SDK, falls vorhanden.
if ! xcode-select -p | grep -q Xcode; then
    SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)
    if [[ -n "${SDK}" ]]; then export SDKROOT="${SDK}"; fi
fi

FLAGS=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then FLAGS+=(--arch arm64 --arch x86_64); fi

swift build "${FLAGS[@]}" --product MacIPMI
swift build "${FLAGS[@]}" --product ipmi-cli
BIN=$(swift build "${FLAGS[@]}" --show-bin-path)

APP=build/MacIPMI.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacIPMI" "$APP/Contents/MacOS/MacIPMI"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/ipmi-cli" build/ipmi-cli
codesign --force --sign - --identifier tech.rabe.ipmi-cli build/ipmi-cli
# The CLI also ships inside the app bundle (the Homebrew cask links it into the PATH).
cp build/ipmi-cli "$APP/Contents/MacOS/ipmi-cli"

PLIST="$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST"; fi
if [[ -n "${BUILD:-}" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "$PLIST"; fi

codesign --force --sign - --identifier tech.rabe.MacIPMI "$APP"

echo "Fertig: $APP ($(lipo -archs "$APP/Contents/MacOS/MacIPMI"))"
echo "CLI:    build/ipmi-cli"
