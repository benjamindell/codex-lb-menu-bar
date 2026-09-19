#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/CodexLBStatus.app"
DIST="$ROOT/dist"
ARCHIVE="$DIST/CodexLBStatus.zip"

if [[ ! -d "$APP" ]]; then
  "$ROOT/build.sh"
fi

mkdir -p "$DIST"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
echo "$ARCHIVE"
