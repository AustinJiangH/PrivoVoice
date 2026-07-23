#!/usr/bin/env bash
# setup-signing.sh — create a stable, self-signed "Voixful Dev" code-signing
# identity so macOS TCC permissions (Input Monitoring, Accessibility, Microphone)
# PERSIST across rebuilds.
#
# Why: ad-hoc signing (`codesign -s -`) produces a different signature every
# build, so TCC treats each rebuild as a new app and your granted permissions
# vanish. A stable self-signed cert keeps one identity across builds, so you
# grant once. Local development only — not trusted by other machines, not a
# substitute for an Apple Developer ID for distribution.
#
# Run once:  ./scripts/setup-signing.sh   (then use make-app.sh as usual)

set -euo pipefail

IDENTITY="Voixful Dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "[signing] '$IDENTITY' already exists — nothing to do."
    exit 0
fi

# OpenSSL 3 is required: macOS /usr/bin/openssl is LibreSSL and lacks both
# -addext (the codeSigning EKU) and -legacy (the PKCS#12 format Keychain needs).
OPENSSL=""
for c in /opt/homebrew/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl "$(brew --prefix openssl@3 2>/dev/null)/bin/openssl"; do
    if [ -x "$c" ] && "$c" version 2>/dev/null | grep -q "OpenSSL 3"; then OPENSSL="$c"; break; fi
done
if [ -z "$OPENSSL" ]; then
    echo "[signing] Need OpenSSL 3. Install it with: brew install openssl@3" >&2
    exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PW="voixful"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "[signing] generating self-signed code-signing certificate…"
"$OPENSSL" req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP/dev.key" -out "$TMP/dev.crt" \
    -subj "/CN=$IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=CA:false" >/dev/null 2>&1

# -legacy: Keychain rejects the modern PKCS#12 format silently without it.
"$OPENSSL" pkcs12 -export -legacy -in "$TMP/dev.crt" -inkey "$TMP/dev.key" \
    -out "$TMP/dev.p12" -password "pass:$PW" >/dev/null 2>&1

echo "[signing] importing into the login keychain…"
security import "$TMP/dev.p12" -k "$KEYCHAIN" -P "$PW" -T /usr/bin/codesign >/dev/null

echo "[signing] trusting it for code signing…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/dev.crt"

echo "[signing] done:"
security find-identity -v -p codesigning | grep "$IDENTITY"
echo "[signing] The FIRST codesign will show one keychain prompt — click 'Always Allow'."
