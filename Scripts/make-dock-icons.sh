#!/bin/bash
# Renders the selectable Dock icons listed in Design/AppIcon/dock-icons.json
# into PinaxApp/PinaxApp/Assets.xcassets/DockIcons/DockIcon-<id>.imageset
# (one 1024 px image each). The entry marked "bundle" is the app's own icon
# and is made by make-app-icon.sh instead. Image sets no longer listed are removed.
#
# Needs node and rsvg-convert (brew install librsvg). Run from anywhere:
#     Scripts/make-dock-icons.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON="$ROOT/Design/AppIcon"
DIR="$ROOT/PinaxApp/PinaxApp/Assets.xcassets/DockIcons"
command -v rsvg-convert >/dev/null || { echo "error: rsvg-convert not found (brew install librsvg)" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$DIR"
printf '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n' > "$DIR/Contents.json"
ids=$(node -e 'for (const i of require(process.argv[1]).icons) if (!i.bundle) console.log(i.id)' "$ICON/dock-icons.json")
for set in "$DIR"/DockIcon-*.imageset; do
  [ -e "$set" ] || continue
  id="${set##*/DockIcon-}"; id="${id%.imageset}"
  grep -qx "$id" <<<"$ids" || { rm -rf "$set"; echo "removed DockIcon-$id"; }
done
for id in $ids; do
  set="$DIR/DockIcon-$id.imageset"; mkdir -p "$set"
  node "$ICON/generate-svg.js" "$ICON/variants/$id.json" "$TMP/$id.svg"
  rsvg-convert -w 1024 -h 1024 "$TMP/$id.svg" -o "$set/$id.png"
  printf '{\n  "images" : [\n    {\n      "filename" : "%s.png",\n      "idiom" : "universal",\n      "scale" : "2x"\n    }\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n' "$id" > "$set/Contents.json"
  echo "DockIcon-$id 1024px"
done
