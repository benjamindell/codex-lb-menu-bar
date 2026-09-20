#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/CodexLBMenuBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -whole-module-optimization \
  -target arm64-apple-macosx13.0 \
  -framework Cocoa -framework SwiftUI -framework ServiceManagement -framework Security \
  "$ROOT/StatusBarLogic.swift" "$ROOT/CredentialStore.swift" "$ROOT/CodexLBMenuBar.swift" \
  -o "$APP/Contents/MacOS/CodexLBMenuBar"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
# A stable designated requirement lets Keychain recognize future ad-hoc signed
# auto-updates as the same app instead of tying access to one build's CDHash.
codesign --force --deep --sign - \
  --requirements '=designated => identifier "com.codexlb.status"' \
  "$APP" >/dev/null
echo "Built $APP"
