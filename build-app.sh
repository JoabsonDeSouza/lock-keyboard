#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$PROJECT_DIR/LockKeyboard.app"

cd "$PROJECT_DIR"
swift build -c release --product LockKeyboard
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
cp .build/release/LockKeyboard "$APP_PATH/Contents/MacOS/LockKeyboard"
if [ -e "$APP_PATH/Contents/MacOS/KeyboardClean" ]; then
  rm "$APP_PATH/Contents/MacOS/KeyboardClean"
fi
cp Info.plist "$APP_PATH/Contents/Info.plist"
cp -R Resources/. "$APP_PATH/Contents/Resources/"
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"
printf 'Built: %s\n' "$APP_PATH"
