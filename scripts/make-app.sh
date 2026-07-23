#!/usr/bin/env bash
# make-app.sh — assemble a real, double-clickable Voixful.app from the SwiftPM
# build. Bundles BOTH processes (UI + engine sidecar) into Contents/MacOS so the
# UI can spawn the sidecar as a sibling, writes the Info.plist, and ad-hoc
# code-signs so microphone + Accessibility grants persist across launches.
#
# Usage:  ./scripts/make-app.sh [output-dir]     (default: ./build)
#
# The result is a genuine GUI app: no terminal, a menu-bar item, stable TCC
# identity. For distribution, replace the ad-hoc "-" identity with a Developer
# ID and notarize.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR="${1:-$ROOT/build}"
APP="$OUT_DIR/Voixful.app"
CONFIG=release

echo "[make-app] building ($CONFIG) — both processes…"
swift build -c "$CONFIG" --product VoixfulDictation
swift build -c "$CONFIG" --product VoixfulEngineHelper

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
VERSION="$(grep -m1 'static let version' Sources/VoixfulKit/Support/AppInfo.swift | sed -E 's/.*"([^"]+)".*/\1/')"

echo "[make-app] assembling $APP (v$VERSION)…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Main UI binary is the bundle's executable; sidecar rides alongside it.
cp "$BIN_DIR/VoixfulDictation" "$APP/Contents/MacOS/Voixful"
cp "$BIN_DIR/VoixfulEngineHelper" "$APP/Contents/MacOS/VoixfulEngineHelper"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Voixful</string>
    <key>CFBundleDisplayName</key><string>Voixful</string>
    <key>CFBundleIdentifier</key><string>com.voixful.dictation</string>
    <key>CFBundleExecutable</key><string>Voixful</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Voixful transcribes your speech on-device while you hold the dictation key.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign the sidecar first, then the app (deep) so the whole bundle is
# consistently signed and TCC keys on a stable identity.
echo "[make-app] code-signing (ad-hoc)…"
codesign --force --sign - "$APP/Contents/MacOS/VoixfulEngineHelper"
codesign --force --deep --sign - "$APP"

echo "[make-app] done: $APP"
echo "[make-app] launch with:  open \"$APP\""
echo "[make-app] first run prompts for Microphone + Accessibility — grant, then relaunch."
