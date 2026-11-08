#!/bin/bash
# Builds Nook with the Swift compiler from Command Line Tools and installs it to /Applications.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="/Applications/Nook.app"
# Earlier builds lived in ~/Applications: remove that copy so only one Nook exists.
OLD_APP="$HOME/Applications/Nook.app"
ARCH="$(uname -m)"
BUILD="$PROJECT_DIR/.build"

# Signing identity: NOOK_SIGN_IDENTITY, else a Developer ID Application certificate (what releases use), else
# "Nook Local Signing" from make-cert.sh, else ad-hoc. A stable identity keeps macOS permissions across rebuilds.
# Developer ID is picked by its SHA-1: a renewed certificate has the same name as the old one.
IDENTITY="${NOOK_SIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] || IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/"Developer ID Application: / { print $2; exit }')"
if [ -z "$IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q "Nook Local Signing"; then
  IDENTITY="Nook Local Signing"
fi
IDENTITY="${IDENTITY:--}"
# Apple's notary service needs a secure timestamp (asked from Apple's server): release.sh sets NOOK_TIMESTAMP=1.
STAMP="--timestamp=none"
[ "${NOOK_TIMESTAMP:-}" = 1 ] && [ "$IDENTITY" != "-" ] && STAMP="--timestamp"

mkdir -p "$BUILD"
swiftc -parse-as-library -target "$ARCH-apple-macosx14.0" -O \
  -framework SwiftUI -framework AppKit -framework Carbon -framework IOKit -framework QuickLookThumbnailing \
  -framework EventKit -framework AVFoundation -framework Speech -framework Contacts -framework IOBluetooth \
  -framework CoreLocation -framework Vision -framework Accelerate -lsqlite3 \
  "$PROJECT_DIR"/Sources/*.swift -o "$BUILD/Nook"

# System "Now Playing" bridge: a small dylib that Apple's perl loads (see Sources/MediaRemote).
clang -dynamiclib -fobjc-arc -O2 -target "$ARCH-apple-macosx14.0" -framework Foundation \
  "$PROJECT_DIR/Sources/MediaRemote/NookMediaRemote.m" -o "$BUILD/libNookMediaRemote.dylib"
# Notarization checks every binary inside the app: the dylib carries the same signature as Nook.
codesign --force --options runtime "$STAMP" --sign "$IDENTITY" "$BUILD/libNookMediaRemote.dylib" 2>/dev/null || {
  echo "Signing with $IDENTITY failed (keychain access denied?); using ad-hoc signature" >&2
  IDENTITY="-" STAMP="--timestamp=none"
  codesign --force --sign - "$BUILD/libNookMediaRemote.dylib"
}

# Drawn again when its script changed: a cached icon would hide a new design.
if [ ! -f "$BUILD/AppIcon.icns" ] || [ "$PROJECT_DIR/make-icon.sh" -nt "$BUILD/AppIcon.icns" ]; then
  "$PROJECT_DIR/make-icon.sh" "$BUILD" >/dev/null
fi

# Assemble and sign the app in .build first; `--build-only` stops there (used by release.sh).
STAGE="$BUILD/Nook.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$PROJECT_DIR/Info.plist" "$STAGE/Contents/Info.plist"
# Version = number of commits: every release is larger than the one before (the updater compares it).
BUILD_NUMBER="${NOOK_BUILD_NUMBER:-$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$STAGE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "1.$BUILD_NUMBER" "$STAGE/Contents/Info.plist"
cp "$BUILD/Nook" "$STAGE/Contents/MacOS/Nook"
cp "$BUILD/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
cp -R "$PROJECT_DIR"/Sources/Localization/*.lproj "$STAGE/Contents/Resources/"
cp "$BUILD/libNookMediaRemote.dylib" "$PROJECT_DIR/Sources/MediaRemote/nook-media.pl" "$STAGE/Contents/Resources/"
# Hardened runtime: other programs cannot inject code into Nook and borrow its permissions
# (Full Disk Access, camera, microphone…). Nook.entitlements lists the protected resources it uses.
SIGN=(--force --options runtime --entitlements "$PROJECT_DIR/Nook.entitlements")
codesign "${SIGN[@]}" "$STAMP" --sign "$IDENTITY" "$STAGE" 2>/dev/null || {
  echo "Signing with $IDENTITY failed (keychain access denied?); using ad-hoc signature" >&2
  codesign "${SIGN[@]}" --sign - "$STAGE"
}
SIGNER="$(codesign -dvv "$STAGE" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [ "${1:-}" = "--build-only" ]; then echo "Built: $STAGE (1.$BUILD_NUMBER, ${SIGNER:-ad-hoc})"; exit 0; fi

pkill -x Nook 2>/dev/null || true
# Wait for the old copy to exit (up to 5 s): two copies at once overwrite each other's files.
for _ in $(seq 50); do pgrep -x Nook >/dev/null || break; sleep 0.1; done
rm -rf "$APP_DIR" "$OLD_APP"
mkdir -p "$(dirname "$APP_DIR")"
ditto "$STAGE" "$APP_DIR"
open "$APP_DIR"
echo "Installed: $APP_DIR (1.$BUILD_NUMBER, ${SIGNER:-ad-hoc})"
