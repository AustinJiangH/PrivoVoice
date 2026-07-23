#!/usr/bin/env bash
# make-app.sh — assemble a real, double-clickable Voixful.app from the SwiftPM
# build. Bundles BOTH processes (UI + engine sidecar) into Contents/MacOS so the
# UI can spawn the sidecar as a sibling, writes the Info.plist, and code-signs
# with the stable "Voixful Dev" identity (from setup-signing.sh) so Microphone +
# Accessibility grants persist across rebuilds. Falls back to ad-hoc signing (no
# persistence) if that identity isn't set up.
#
# Usage:  ./scripts/make-app.sh [output-dir]     (default: ./build)
#
# The result is a genuine GUI app: no terminal, a menu-bar item, stable TCC
# identity. For distribution, replace the self-signed identity with a Developer
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

# Sign with the stable self-signed identity if present (so TCC permissions
# persist across rebuilds), else fall back to ad-hoc. Sign inside-out: the nested
# sidecar first, then the app bundle (no --deep — signing the nested binary by
# hand is the reliable path with a self-signed identity).
IDENTITY="Voixful Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    SIGN_ID="$IDENTITY"
    echo "[make-app] code-signing with '$IDENTITY' — Microphone / Accessibility grants will persist…"
else
    SIGN_ID="-"
    echo "[make-app] '$IDENTITY' not found — ad-hoc signing (you'll re-grant permissions each build)."
    echo "[make-app] Run ./scripts/setup-signing.sh once to make grants persist."
fi
codesign --force --sign "$SIGN_ID" "$APP/Contents/MacOS/VoixfulEngineHelper"
codesign --force --sign "$SIGN_ID" "$APP"

echo "[make-app] done: $APP"
echo "[make-app] launch with:  open \"$APP\""
echo "[make-app] first run prompts for Microphone + Accessibility — grant, then relaunch."
