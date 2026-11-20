#!/bin/bash
# Renders Design/AppIcon/pinax.svg (written by Design/AppIcon/generate-svg.js
# from pinax.json) into the ten AppIcon slots
# (PinaxApp/PinaxApp/Assets.xcassets/AppIcon.appiconset). The slot structure
# and file names in Contents.json stay as they are; only the PNGs change.
# Every size is downsampled from one 1024 render, so the texture filters
# (grain, linen, paint wear) look the same at every size.
#
# Needs rsvg-convert (brew install librsvg). Run from anywhere:
#     Scripts/make-app-icon.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/Design/AppIcon/pinax.svg"
SET="$ROOT/PinaxApp/PinaxApp/Assets.xcassets/AppIcon.appiconset"
command -v rsvg-convert >/dev/null || { echo "error: rsvg-convert not found (brew install librsvg)" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
rsvg-convert -w 1024 -h 1024 "$SVG" -o "$TMP/1024.png"
for pt in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((pt * scale))
    suffix=""; [ "$scale" = 2 ] && suffix="@2x"
    name="icon_${pt}x${pt}${suffix}.png"
    if [ "$px" = 1024 ]; then cp "$TMP/1024.png" "$SET/$name"
    else sips -s format png -z "$px" "$px" "$TMP/1024.png" --out "$SET/$name" >/dev/null; fi
    echo "$name ${px}px"
  done
done
