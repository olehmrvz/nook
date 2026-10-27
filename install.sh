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
  -framework CoreLocation -framework Vision -lsqlite3 \
  "$PROJECT_DIR"/Sources/*.swift -o "$BUILD/Nook"

# System "Now Playing" bridge: a small dylib that Apple's perl loads (see Sources/MediaRemote).
clang -dynamiclib -fobjc-arc -O2 -target "$ARCH-apple-macosx14.0" -framework Foundation \
  "$PROJECT_DIR/Sources/MediaRemote/NookMediaRemote.m" -o "$BUILD/libNookMediaRemote.dylib"
codesign --force --sign - "$BUILD/libNookMediaRemote.dylib" 2>/dev/null

if [ ! -f "$BUILD/AppIcon.icns" ]; then
  "$PROJECT_DIR/make-icon.sh" "$BUILD" >/dev/null
fi

pkill -x Nook 2>/dev/null || true
# Wait for the old copy to exit (up to 5 s): two copies at once overwrite each other's files.
for _ in $(seq 50); do pgrep -x Nook >/dev/null || break; sleep 0.1; done
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BUILD/Nook" "$APP_DIR/Contents/MacOS/Nook"
cp "$BUILD/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$BUILD/libNookMediaRemote.dylib" "$PROJECT_DIR/Sources/MediaRemote/nook-media.pl" "$APP_DIR/Contents/Resources/"
# A stable identity keeps macOS permissions across rebuilds (see make-cert.sh); ad-hoc otherwise.
IDENTITY="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "Nook Local Signing"; then IDENTITY="Nook Local Signing"; fi
# Hardened runtime: other programs cannot inject code into Nook and borrow its permissions
# (Full Disk Access, camera, microphone…). Nook.entitlements lists the protected resources it uses.
SIGN=(--force --options runtime --entitlements "$PROJECT_DIR/Nook.entitlements")
codesign "${SIGN[@]}" --sign "$IDENTITY" "$APP_DIR" 2>/dev/null || {
  echo "Signing with $IDENTITY failed (keychain access denied?); using ad-hoc signature" >&2
  codesign "${SIGN[@]}" --sign - "$APP_DIR"
}

open "$APP_DIR"
echo "Installed: $APP_DIR"
