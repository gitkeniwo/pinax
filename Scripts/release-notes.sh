#!/bin/bash
# Checks that <version> is releasable and prints its release notes: the
# version's CHANGELOG.md section.
#
#     Scripts/release-notes.sh <version>
#
# Fails when the version is not x.y.z, when PinaxVersion.current (what
# `pinax --version` prints) differs, or when CHANGELOG.md has no non-empty
# "## <version>" section.

set -euo pipefail

[ $# -eq 1 ] || { echo "usage: Scripts/release-notes.sh <version>" >&2; exit 64; }
VERSION="$1"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like 1.2.3, got '$VERSION'" >&2
  exit 64
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

CLI_VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/CatalogCore/CatalogCore.swift)"
if [ "$CLI_VERSION" != "$VERSION" ]; then
  echo "error: PinaxVersion.current is '$CLI_VERSION', not '$VERSION'; bump it first" >&2
  exit 1
fi

CHANGES="$(awk -v v="$VERSION" '/^## /{f = (index($0, "## " v " ") == 1 || $0 == "## " v); next} f' CHANGELOG.md)"
if [ -z "$(printf '%s' "$CHANGES" | tr -d '[:space:]')" ]; then
  echo "error: CHANGELOG.md has no '## $VERSION' section" >&2
  exit 1
fi

printf '%s\n' "$CHANGES"
