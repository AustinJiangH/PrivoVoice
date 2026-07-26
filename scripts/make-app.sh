#!/usr/bin/env bash
# make-app.sh — assemble a real, double-clickable PrivoVoice.app from the SwiftPM
# build. Bundles BOTH processes (UI + engine sidecar) into Contents/MacOS so the
# UI can spawn the sidecar as a sibling, writes the Info.plist, and code-signs
# with the stable "PrivoVoice Dev" identity (from setup-signing.sh) so Microphone +
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
APP="$OUT_DIR/PrivoVoice.app"
CONFIG=release

echo "[make-app] building ($CONFIG) — both processes…"
swift build -c "$CONFIG" --product PrivoVoice
swift build -c "$CONFIG" --product PrivoVoiceHelper

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
VERSION="$(grep -m1 'static let version' Sources/PrivoVoiceKit/Support/AppInfo.swift | sed -E 's/.*"([^"]+)".*/\1/')"

echo "[make-app] assembling $APP (v$VERSION)…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Main UI binary is the bundle's executable; sidecar rides alongside it.
cp "$BIN_DIR/PrivoVoice" "$APP/Contents/MacOS/PrivoVoice"
cp "$BIN_DIR/PrivoVoiceHelper" "$APP/Contents/MacOS/PrivoVoiceHelper"

# SwiftPM resource bundles (MLX metallib, Voixful model registry, Hub data).
# Inside an .app, Bundle.main resolves to the app bundle for BOTH processes —
# even the bare sidecar in Contents/MacOS — so Bundle.module looks them up in
# Contents/Resources. Missing bundles fail at RUNTIME, not launch (verified:
# the formatter LLM's Metal kernels live in mlx-swift_Cmlx.bundle, and without
# it the sidecar dies silently on the first format request).
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PrivoVoice</string>
    <key>CFBundleDisplayName</key><string>PrivoVoice</string>
    <key>CFBundleIdentifier</key><string>com.privovoice.app</string>
    <key>CFBundleExecutable</key><string>PrivoVoice</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>PrivoVoice transcribes your speech on-device while you hold the dictation key.</string>
</dict>
</plist>
PLIST

# Sign with the stable self-signed identity if present (so TCC permissions
# persist across rebuilds), else fall back to ad-hoc. Sign inside-out: the nested
# sidecar first, then the app bundle (no --deep — signing the nested binary by
# hand is the reliable path with a self-signed identity).
IDENTITY="PrivoVoice Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    SIGN_ID="$IDENTITY"
    echo "[make-app] code-signing with '$IDENTITY' — Microphone / Accessibility grants will persist…"
else
    SIGN_ID="-"
    echo "[make-app] '$IDENTITY' not found — ad-hoc signing (you'll re-grant permissions each build)."
    echo "[make-app] Run ./scripts/setup-signing.sh once to make grants persist."
fi
# Nested resource bundles count as subcomponents — sign them first or the
# outer app signature is rejected.
for bundle in "$APP"/Contents/Resources/*.bundle; do
    [ -e "$bundle" ] || continue
    codesign --force --sign "$SIGN_ID" "$bundle"
done
codesign --force --sign "$SIGN_ID" "$APP/Contents/MacOS/PrivoVoiceHelper"
codesign --force --sign "$SIGN_ID" "$APP"

echo "[make-app] done: $APP"
echo "[make-app] launch with:  open \"$APP\""
echo "[make-app] first run prompts for Microphone + Accessibility — grant, then relaunch."
