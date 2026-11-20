#!/bin/bash
# Adds (or re-renders) a selectable Dock icon from a recipe copied off the
# tuner board's 「复制配方」 button:
#     Scripts/add-dock-icon.sh <id> "<Name>" [recipe.json]
# The recipe comes from recipe.json, else from the clipboard (pbpaste).
# Writes Design/AppIcon/variants/<id>.json, lists the icon in dock-icons.json
# and in DockIconCatalog (Sources/PinaxUI/Appearance/DockIcons.swift), then
# runs make-dock-icons.sh. An id already listed only gets its recipe replaced.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON="$ROOT/Design/AppIcon"
[ $# -ge 2 ] || { echo "usage: $0 <id> \"<Name>\" [recipe.json]" >&2; exit 2; }
id="$1"; name="$2"
[[ "$id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "error: id must be kebab-case (a-z, 0-9, -)" >&2; exit 2; }
[[ "$name" != *'"'* && "$name" != *'\'* ]] || { echo "error: name must not contain quotes or backslashes" >&2; exit 2; }
if [ $# -ge 3 ]; then recipe="$(cat "$3")"; else recipe="$(pbpaste)"; fi
RECIPE="$recipe" node - "$ICON" "$ROOT/Sources/PinaxUI/Appearance/DockIcons.swift" "$id" "$name" <<'JS'
const fs = require('fs');
const [icon, swift, id, name] = process.argv.slice(2);
let r;
try { r = JSON.parse(process.env.RECIPE); } catch (e) { console.error('error: the recipe is not JSON (copy it with the board\'s 复制配方 button)'); process.exit(1); }
if (!r || typeof r !== 'object' || Array.isArray(r) || !('cloth' in r)) { console.error('error: that JSON is not a tuner recipe'); process.exit(1); }
fs.writeFileSync(`${icon}/variants/${id}.json`, JSON.stringify(r, null, 1) + '\n');
const manPath = `${icon}/dock-icons.json`, man = JSON.parse(fs.readFileSync(manPath, 'utf8'));
const listed = man.icons.find((i) => i.id === id);
if (listed && listed.bundle) { console.error('error: the bundle icon is made by make-app-icon.sh from pinax.json'); process.exit(1); }
if (!listed) {
  man.icons.push({ id, name });
  const entry = (i) => '    ' + JSON.stringify(i).replace(/":/g, '": ').replace(/,"/g, ', "');
  const head = Object.entries(man).filter(([k]) => k !== 'icons').map(([k, v]) => `  ${JSON.stringify(k)}: ${JSON.stringify(v)},\n`).join('');
  fs.writeFileSync(manPath, '{\n' + head + '  "icons": [\n' + man.icons.map(entry).join(',\n') + '\n  ]\n}\n');
  const src = fs.readFileSync(swift, 'utf8'), lines = src.split('\n');
  const last = lines.map((l, i) => (/^\s*DockIcon\(id: ".*", isBundle: (true|false)\),$/.test(l) ? i : -1)).filter((i) => i >= 0).pop();
  if (last === undefined) { console.error('error: DockIconCatalog.icons not found in ' + swift); process.exit(1); }
  lines.splice(last + 1, 0, `    DockIcon(id: "${id}", name: "${name}", isBundle: false),`);
  fs.writeFileSync(swift, lines.join('\n'));
  console.log(`listed ${id} "${name}"`);
} else console.log(`${id} already listed; recipe replaced`);
JS
"$ROOT/Scripts/make-dock-icons.sh"
