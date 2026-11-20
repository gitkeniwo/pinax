#!/bin/bash
# Renders the Homebrew cask, formula and tap README for a release built by
# Scripts/build-dist.sh into <out-dir>/tap.
#
#     Scripts/render-tap.sh <version> <out-dir> [<base-url>]
#
# <base-url> is the release download prefix; it defaults to this repository's
# GitHub Releases. Override it only to test a local tap (file://...).

set -euo pipefail

[ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: Scripts/render-tap.sh <version> <out-dir> [<base-url>]" >&2; exit 64; }
VERSION="$1"
OUT="$2"
BASE_URL="${3:-https://github.com/gitkeniwo/pinax/releases/download}"

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

APP_SHA256="$(shasum -a 256 "$OUT/Pinax-$VERSION.zip" | cut -d' ' -f1)"
CLI_SHA256="$(shasum -a 256 "$OUT/pinax-cli-$VERSION.zip" | cut -d' ' -f1)"

TAP="$OUT/tap"
rm -rf "$TAP"
mkdir -p "$TAP/Casks" "$TAP/Formula"
render() {
  sed -e "s|@VERSION@|$VERSION|g" \
      -e "s|@APP_SHA256@|$APP_SHA256|g" \
      -e "s|@CLI_SHA256@|$CLI_SHA256|g" \
      -e "s|@BASE_URL@|$BASE_URL|g" "$1" > "$2"
}
render Packaging/homebrew-pinax/Casks/pinax.rb.in "$TAP/Casks/pinax.rb"
render Packaging/homebrew-pinax/Formula/pinax.rb.in "$TAP/Formula/pinax.rb"
cp Packaging/homebrew-pinax/README.md "$TAP/README.md"
if grep -rn "@[A-Z_0-9]*@" "$TAP"; then
  echo "error: unrendered placeholders above" >&2
  exit 1
fi
# Copied after the placeholder check: the icon's bytes can match the pattern.
cp Packaging/homebrew-pinax/icon.png "$TAP/icon.png"
echo "$TAP"
