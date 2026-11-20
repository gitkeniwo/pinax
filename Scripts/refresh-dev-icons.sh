#!/bin/bash
# Make macOS forget stale Pinax icons after a rebuild.
#
# Xcode's debug builds and the installed /Applications/Pinax.app share the
# bundle id gitkeniwo.PinaxApp, so Launch Services and the Dock can keep
# showing whichever copy's icon they cached first. This script:
#   1. refuses to run while any Pinax copy is running (quit it yourself);
#   2. unregisters every DerivedData PinaxApp.app from Launch Services;
#   3. deletes the PinaxApp-* DerivedData folders (unless --keep-derived-data;
#      Xcode then does one full rebuild on the next ⌘R);
#   4. re-registers /Applications/Pinax.app if it is installed;
#   5. restarts the user's icon agent, the Dock and Finder.
# --deep additionally clears the system icon cache with sudo (you type the
# password); restart the Mac afterwards for it to take full effect.
#
# Usage: Scripts/refresh-dev-icons.sh [--keep-derived-data] [--deep]

set -euo pipefail

BUNDLE_ID="gitkeniwo.PinaxApp"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
INSTALLED="/Applications/Pinax.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

keep_derived=0
deep=0
for arg in "$@"; do
  case "$arg" in
    --keep-derived-data) keep_derived=1 ;;
    --deep) deep=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ -n "$(osascript -e "tell application \"System Events\" to get unix id of every process whose bundle identifier is \"$BUNDLE_ID\"" 2>/dev/null)" ]; then
  echo "Pinax is running. Quit it (and stop the Xcode run) first, then run this again." >&2
  exit 1
fi

shopt -s nullglob
apps=("$DERIVED"/PinaxApp-*/Build/Products/*/PinaxApp.app)
for app in "${apps[@]}"; do
  echo "unregister  $app"
  "$LSREGISTER" -u "$app" || true
done

if [ "$keep_derived" -eq 0 ]; then
  for dir in "$DERIVED"/PinaxApp-*; do
    echo "remove      $dir"
    rm -rf "$dir"
  done
fi

if [ -d "$INSTALLED" ]; then
  echo "register    $INSTALLED"
  "$LSREGISTER" -f "$INSTALLED"
  touch "$INSTALLED"
fi

if [ "$deep" -eq 1 ]; then
  echo "clearing the system icon cache (sudo asks for your password)"
  sudo rm -rf /Library/Caches/com.apple.iconservices.store
  sudo find /private/var/folders -name com.apple.iconservices -prune -exec rm -rf {} + 2>/dev/null || true
fi

killall iconservicesagent 2>/dev/null || true
killall Dock
killall Finder

echo "done."
if [ "$deep" -eq 1 ]; then
  echo "Restart the Mac so the icon cache is rebuilt from scratch."
fi
echo "In Xcode: Product ▸ Clean Build Folder (⇧⌘K), then ⌘R."
echo "Still the old Dock icon? Check Pinax Settings ▸ Appearance ▸ App Icon — that choice overrides it at run time."
