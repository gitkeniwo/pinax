#!/bin/bash
# CI only: imports the signing certificate from the environment into a
# temporary keychain and exports PINAX_SIGN_IDENTITY / PINAX_SIGN_KEYCHAIN
# through $GITHUB_ENV. Without SIGNING_CERT_P12 the build stays ad-hoc signed.
#
# Environment: SIGNING_CERT_P12 (base64 .p12), SIGNING_CERT_PASSWORD.

set -euo pipefail

if [ -z "${SIGNING_CERT_P12:-}" ]; then
  echo "SIGNING_CERT_P12 is not set; the build will be ad-hoc signed."
  exit 0
fi

KEYCHAIN="$RUNNER_TEMP/pinax-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"
P12="$RUNNER_TEMP/pinax-signing.p12"
printf '%s' "$SIGNING_CERT_P12" | base64 --decode > "$P12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$SIGNING_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
rm -f "$P12"

IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | sed -n 's/.*\([0-9A-F]\{40\}\).*/\1/p' | head -1)"
[ -n "$IDENTITY" ] || { echo "error: no code signing identity in the imported certificate" >&2; exit 1; }
echo "PINAX_SIGN_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
echo "PINAX_SIGN_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"
echo "Signing with certificate $IDENTITY"
