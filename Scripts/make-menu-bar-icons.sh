#!/bin/bash
# Renders the selectable menu bar icons listed in Design/MenuBarIcon/menu-bar-icons.json
# into PinaxApp/PinaxApp/Assets.xcassets/MenuBarIcons/MenuBarIcon-<id>.imageset:
# 18×18 pt PNGs at 1x/2x/3x, marked as a template image so macOS tints it
# for light and dark menu bars (PNG, not PDF: rsvg's PDF soft masks draw
# blank in Core Graphics). Image sets no longer listed are removed.
#
# Needs node and rsvg-convert (brew install librsvg). Run from anywhere:
#     Scripts/make-menu-bar-icons.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Design/MenuBarIcon"
DIR="$ROOT/PinaxApp/PinaxApp/Assets.xcassets/MenuBarIcons"
command -v rsvg-convert >/dev/null || { echo "error: rsvg-convert not found (brew install librsvg)" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$DIR"
printf '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n' > "$DIR/Contents.json"
ids=$(node -e '
const { G } = require(process.argv[1] + "/glyphs.js"), fs = require("fs");
for (const i of require(process.argv[1] + "/menu-bar-icons.json").icons) {
  if (!G[i.glyph]) { console.error("error: no glyph " + i.glyph); process.exit(1); }
  fs.writeFileSync(process.argv[2] + "/" + i.id + ".svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"36\" height=\"36\" viewBox=\"0 0 36 36\">" + G[i.glyph].body("#000") + "</svg>");
  console.log(i.id);
}' "$SRC" "$TMP")
for set in "$DIR"/MenuBarIcon-*.imageset; do
  [ -e "$set" ] || continue
  id="${set##*/MenuBarIcon-}"; id="${id%.imageset}"
  grep -qx "$id" <<<"$ids" || { rm -rf "$set"; echo "removed MenuBarIcon-$id"; }
done
for id in $ids; do
  set="$DIR/MenuBarIcon-$id.imageset"; mkdir -p "$set"
  rm -f "$set"/*
  for k in 1 2 3; do rsvg-convert -w $((18 * k)) -h $((18 * k)) "$TMP/$id.svg" -o "$set/$id@${k}x.png"; done
  printf '{\n  "images" : [\n    {\n      "filename" : "%s@1x.png",\n      "idiom" : "universal",\n      "scale" : "1x"\n    },\n    {\n      "filename" : "%s@2x.png",\n      "idiom" : "universal",\n      "scale" : "2x"\n    },\n    {\n      "filename" : "%s@3x.png",\n      "idiom" : "universal",\n      "scale" : "3x"\n    }\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n  "properties" : {\n    "template-rendering-intent" : "template"\n  }\n}\n' "$id" "$id" "$id" > "$set/Contents.json"
  echo "MenuBarIcon-$id 18pt"
done
