#!/bin/bash
# Builds the distributable Pinax app and `pinax` CLI, signs them, and zips them.
#
#     Scripts/build-dist.sh <version> <label> <out-dir>
#
# <version> becomes CFBundleShortVersionString. <label> names the zips:
# Pinax-<label>.zip and pinax-cli-<label>.zip (a release uses its version,
# the nightly build uses "nightly"). Both are built for arm64 and x86_64 with
# the dependency versions pinned in Package.resolved.
#
# Environment:
#   PINAX_SIGN_IDENTITY   codesign identity. Default "-" (ad-hoc). A stable
#                         identity keeps Keychain "Always Allow" across updates.
#   PINAX_SIGN_KEYCHAIN   keychain that holds the identity (optional).

set -euo pipefail

[ $# -eq 3 ] || { echo "usage: Scripts/build-dist.sh <version> <label> <out-dir>" >&2; exit 64; }
VERSION="$1"
LABEL="$2"
OUT="$3"

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

SIGN_IDENTITY="${PINAX_SIGN_IDENTITY:--}"
KEYCHAIN_ARGS=()
[ -n "${PINAX_SIGN_KEYCHAIN:-}" ] && KEYCHAIN_ARGS=(--keychain "$PINAX_SIGN_KEYCHAIN")
# Offset so build numbers keep increasing past the builds made before the
# public history began.
BUILD_NUMBER="$(( 1000 + $(git rev-list --count HEAD) ))"
COMMIT="$(git rev-parse --short HEAD)"

step() { printf '\n==> %s\n' "$*"; }

rm -rf "$OUT/stage"
mkdir -p "$OUT/stage"

step "Pinax $VERSION ($LABEL, build $BUILD_NUMBER, commit $COMMIT)"

step "Building the app (Release)"
# CODE_SIGNING_ALLOWED=NO: the app is signed below with SIGN_IDENTITY.
xcodebuild -quiet \
  -project PinaxApp/PinaxApp.xcodeproj -scheme PinaxApp -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$OUT/xcode" -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
APP="$OUT/stage/Pinax.app"
# The product is PinaxApp.app; it ships as Pinax.app. The bundle directory
# name is not part of the signature.
ditto "$OUT/xcode/Build/Products/Release/PinaxApp.app" "$APP"

step "Building the pinax command-line tool"
swift build --quiet -c release --product pinax --only-use-versions-from-resolved-file \
  --arch arm64 --arch x86_64 --scratch-path "$OUT/swiftpm"
CLI="$OUT/stage/pinax"
cp "$(swift build -c release --arch arm64 --arch x86_64 --scratch-path "$OUT/swiftpm" --show-bin-path)/pinax" "$CLI"

step "Signing (identity '$SIGN_IDENTITY')"
codesign --force --deep --timestamp=none ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$SIGN_IDENTITY" "$APP"
codesign --force --timestamp=none ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --identifier gitkeniwo.pinax --sign "$SIGN_IDENTITY" "$CLI"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$CLI"
codesign -d -r- "$APP" 2>&1 | tail -1

step "Checking versions"
PLIST="$APP/Contents/Info.plist"
echo "CFBundleShortVersionString: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
echo "CFBundleVersion:            $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
echo "app architectures:          $(lipo -archs "$APP/Contents/MacOS/PinaxApp")"
echo "cli architectures:          $(lipo -archs "$CLI")"

step "Zipping"
(cd "$OUT/stage" && ditto -c -k --keepParent Pinax.app "$OUT/Pinax-$LABEL.zip")
(cd "$OUT/stage" && ditto -c -k pinax "$OUT/pinax-cli-$LABEL.zip")
(cd "$OUT" && shasum -a 256 "Pinax-$LABEL.zip" "pinax-cli-$LABEL.zip" > SHA256SUMS)
cat "$OUT/SHA256SUMS"
