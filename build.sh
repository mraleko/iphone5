#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/iPhone 5 Generator.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" \
  "$ROOT/Sources/Converter.swift" "$ROOT/Sources/main.swift" \
  -o "$APP/Contents/MacOS/iPhone5Generator"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf '\nBuilt: %s\nOpen this app in Finder to get started.\n' "$APP"
