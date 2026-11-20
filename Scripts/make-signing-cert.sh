#!/bin/bash
# Creates a self-signed code signing certificate for Pinax builds and exports
# it as a password-protected .p12, ready to store as a CI secret.
#
#     Scripts/make-signing-cert.sh <out-dir>
#
# Writes <out-dir>/pinax-signing.p12 and prints its password. A stable
# certificate gives every build the same designated requirement, so Keychain
# keeps "Always Allow" across updates. It does not make Pinax notarized.

set -euo pipefail

[ $# -eq 1 ] || { echo "usage: Scripts/make-signing-cert.sh <out-dir>" >&2; exit 64; }
OUT="$1"
NAME="Pinax Release Signing"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASSWORD="$(openssl rand -base64 24)"
# -legacy: the macOS keychain cannot import OpenSSL 3's default PKCS#12 ciphers.
LEGACY=()
openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && LEGACY=(-legacy)
openssl pkcs12 -export ${LEGACY[@]+"${LEGACY[@]}"} -name "$NAME" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$OUT/pinax-signing.p12" -passout "pass:$PASSWORD"
chmod 600 "$OUT/pinax-signing.p12"

echo "certificate: $NAME"
echo "file:        $OUT/pinax-signing.p12"
echo "password:    $PASSWORD"
