#!/bin/bash
# Builds Nook with the Swift compiler from Command Line Tools and installs it to ~/Applications.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications/Nook.app"
ARCH="$(uname -m)"
BUILD="$PROJECT_DIR/.build"

mkdir -p "$BUILD"
swiftc -parse-as-library -target "$ARCH-apple-macosx14.0" -O \
  -framework SwiftUI -framework AppKit -framework Carbon -framework IOKit -framework QuickLookThumbnailing \
  -framework EventKit -framework AVFoundation -framework Speech -framework Contacts -framework IOBluetooth \
  -framework CoreLocation -lsqlite3 \
  "$PROJECT_DIR"/Sources/*.swift -o "$BUILD/Nook"

if [ ! -f "$BUILD/AppIcon.icns" ]; then
  "$PROJECT_DIR/make-icon.sh" "$BUILD" >/dev/null
fi

pkill -x Nook 2>/dev/null || true
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BUILD/Nook" "$APP_DIR/Contents/MacOS/Nook"
cp "$BUILD/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# A stable identity keeps macOS permissions across rebuilds (see make-cert.sh); ad-hoc otherwise.
IDENTITY="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "Nook Local Signing"; then IDENTITY="Nook Local Signing"; fi
codesign --force --sign "$IDENTITY" "$APP_DIR" 2>/dev/null || {
  echo "Signing with $IDENTITY failed (keychain access denied?); using ad-hoc signature" >&2
  codesign --force --sign - "$APP_DIR"
}

open "$APP_DIR"
echo "Installed: $APP_DIR"
