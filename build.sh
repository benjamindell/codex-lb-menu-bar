#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/CodexLBMenuBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -whole-module-optimization \
  -target arm64-apple-macosx13.0 \
  -framework Cocoa -framework SwiftUI -framework ServiceManagement \
  "$ROOT/StatusBarLogic.swift" "$ROOT/CodexLBMenuBar.swift" \
  -o "$APP/Contents/MacOS/CodexLBMenuBar"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
