#!/usr/bin/env bash
# make-dmg.sh — package PrivoVoice into a signed, drag-and-drop installable DMG:
# download, drag the app onto the Applications shortcut, launch, and onboarding
# takes it from there.
#
# Usage:  ./scripts/make-dmg.sh          # → dist/PrivoVoice-<version>.dmg
#
# Builds the app via make-app.sh (which owns all build/bundle logic), then picks
# the most-trusted signing tier available:
#
#   • Developer ID Application identity in the keychain
#       → re-sign everything inside-out with hardened runtime + timestamp,
#         sign the DMG, and notarize + staple when credentials exist:
#         either a notarytool keychain profile ($NOTARY_PROFILE, default
#         "privovoice", created with `xcrun notarytool store-credentials`) or —
#         for CI — an App Store Connect API key via NOTARY_KEY (path to .p8),
#         NOTARY_KEY_ID, and NOTARY_ISSUER.
#   • Otherwise
#       → keep make-app.sh's signature ("PrivoVoice Dev" or ad-hoc); recipients
#         must right-click → Open the first time (Gatekeeper).
#
# Pure hdiutil — no Homebrew/node dependencies. The Finder window layout step is
# a nice-to-have: it degrades gracefully when Finder scripting is unavailable
# (and is skipped outright on CI).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ── 1. Fresh, signed app build (make-app.sh owns this) ───────────────────────
echo "[make-dmg] building the app via make-app.sh…"
./scripts/make-app.sh

APP="$ROOT/build/PrivoVoice.app"
VERSION="$(grep -m1 'static let version' Sources/PrivoVoiceKit/Support/AppInfo.swift | sed -E 's/.*"([^"]+)".*/\1/')"
VOL_NAME="PrivoVoice $VERSION"
DIST="$ROOT/dist"
DMG="$DIST/PrivoVoice-$VERSION.dmg"
STAGING="$ROOT/build/dmg-staging"
RW_DMG="$ROOT/build/dmg-rw.dmg"
MOUNT_POINT=""

cleanup() {
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGING" "$RW_DMG"
}
trap cleanup EXIT

# Idempotency: detach stale mounts from interrupted runs, clear old staging.
for vol in "/Volumes/$VOL_NAME" "/Volumes/$VOL_NAME "*; do
    [ -d "$vol" ] || continue
    echo "[make-dmg] detaching stale mount: $vol"
    hdiutil detach "$vol" -force >/dev/null 2>&1 || true
done
rm -rf "$STAGING" "$RW_DMG"
rm -f "$DMG"
mkdir -p "$DIST"

# ── 2. Signing tier (most-trusted wins) ──────────────────────────────────────
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null \
          | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)"
if [ -n "$DEV_ID" ]; then
    echo "[make-dmg] signing tier: Developer ID — '$DEV_ID' (hardened runtime + timestamp)…"
    # Inside-out, same order as make-app.sh: nested resource bundles → sidecar
    # helper → app bundle.
    for bundle in "$APP"/Contents/Resources/*.bundle; do
        [ -e "$bundle" ] || continue
        codesign --force --sign "$DEV_ID" --options runtime --timestamp "$bundle"
    done
    codesign --force --sign "$DEV_ID" --options runtime --timestamp "$APP/Contents/MacOS/PrivoVoiceHelper"
    codesign --force --sign "$DEV_ID" --options runtime --timestamp "$APP"
    codesign --verify --deep --strict "$APP"
else
    echo "[make-dmg] signing tier: dev/ad-hoc — keeping make-app.sh's signature as-is."
    echo "[make-dmg]   Gatekeeper caveat: recipients must right-click PrivoVoice.app → Open"
    echo "[make-dmg]   the first time. Install a 'Developer ID Application' identity to fix."
fi

# ── 3. Stage DMG contents ────────────────────────────────────────────────────
echo "[make-dmg] staging DMG contents…"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/PrivoVoice.app"     # ditto preserves signatures/xattrs
ln -s /Applications "$STAGING/Applications"
# Volume icon lives at the volume root; the custom-icon Finder bit is flipped
# on the mounted volume below.
cp "$ROOT/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"

# ── 4. Read-write image → icon + layout → compressed UDZO ────────────────────
SIZE_MB=$(( $(du -sm "$STAGING" | cut -f1) + 20 ))
echo "[make-dmg] creating read-write image (${SIZE_MB} MB)…"
hdiutil create -srcfolder "$STAGING" -volname "$VOL_NAME" -fs HFS+ \
    -format UDRW -size "${SIZE_MB}m" -ov "$RW_DMG" >/dev/null

echo "[make-dmg] mounting to set volume icon + window layout…"
MOUNT_POINT="$(hdiutil attach "$RW_DMG" -noautoopen | grep -o '/Volumes/.*' | tail -1)"

# Volume icon: flip the has-custom-icon bit on the volume root so Finder uses
# .VolumeIcon.icns. SetFile needs the Xcode CLT; fall back to raw FinderInfo
# (32 bytes, folder flags at offset 8, kHasCustomIcon = 0x0400).
if xcrun SetFile -a C "$MOUNT_POINT" 2>/dev/null; then
    echo "[make-dmg] volume icon set (SetFile)."
elif xattr -wx com.apple.FinderInfo \
        "00000000000000000400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" \
        "$MOUNT_POINT" 2>/dev/null; then
    echo "[make-dmg] volume icon set (FinderInfo xattr)."
else
    echo "[make-dmg] WARNING: could not set the volume-icon bit — generic icon will show."
fi

# Finder window layout (nice-to-have): icon view, app left / Applications
# right. Requires Finder + Apple Events; degrade gracefully when headless.
finder_layout() {
    osascript <<OSA
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 780, 470}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 100
        set position of item "PrivoVoice.app" of container window to {150, 170}
        set position of item "Applications" of container window to {430, 170}
        close
    end tell
end tell
OSA
}
if [ -n "${CI:-}" ]; then
    echo "[make-dmg] CI detected — skipping Finder window layout."
elif finder_layout >/dev/null 2>&1; then
    echo "[make-dmg] Finder window layout applied."
else
    echo "[make-dmg] Finder scripting unavailable — shipping default layout (harmless)."
fi

sync
echo "[make-dmg] detaching…"
detached=""
for _ in 1 2 3 4 5; do
    if hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1; then detached=1; break; fi
    sleep 1
done
[ -n "$detached" ] || hdiutil detach "$MOUNT_POINT" -force >/dev/null
MOUNT_POINT=""

echo "[make-dmg] converting to compressed UDZO…"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null

# ── 5. Sign + notarize the DMG (Developer ID tier only) ──────────────────────
if [ -n "$DEV_ID" ]; then
    echo "[make-dmg] signing the DMG…"
    codesign --force --sign "$DEV_ID" --timestamp "$DMG"

    NOTARY_PROFILE="${NOTARY_PROFILE:-privovoice}"
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "[make-dmg] notarizing (keychain profile '$NOTARY_PROFILE') — takes a few minutes…"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        echo "[make-dmg] notarized + stapled."
    elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
        # Headless/CI path: App Store Connect API key, no keychain profile.
        echo "[make-dmg] notarizing (API key $NOTARY_KEY_ID) — takes a few minutes…"
        xcrun notarytool submit "$DMG" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER" --wait
        xcrun stapler staple "$DMG"
        echo "[make-dmg] notarized + stapled."
    else
        echo "[make-dmg] WARNING: Developer ID-signed but NOT notarized — Gatekeeper will"
        echo "[make-dmg]   still warn on other Macs. Set up credentials once with:"
        echo "[make-dmg]     xcrun notarytool store-credentials $NOTARY_PROFILE \\"
        echo "[make-dmg]         --apple-id you@example.com --team-id YOURTEAMID"
        echo "[make-dmg]   then re-run (export NOTARY_PROFILE=<name> if you chose another name)."
    fi
fi

echo "[make-dmg] done: $DMG ($(du -h "$DMG" | cut -f1))"
