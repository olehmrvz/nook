#!/bin/bash
# Publishes the current commit as a GitHub release. Every installed Nook checks the latest release every
# 6 hours, downloads and checks it, and offers it in the notch; it installs when the person clicks Install
# (Sources/Updater.swift). Run from a clean tree.
# A release is signed with Nook's Developer ID and notarized by Apple, so a download opens without warnings.
# It carries Nook.dmg (for people) and Nook.zip (for the updater). One-time setup: docs/DEVELOPMENT.md.
# `--local-signing`: the one bridge release signed with "Nook Local Signing", not notarized. Copies from before
# Developer ID get from it an updater that also accepts Developer ID builds.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="olehmrvz/nook"
TEAM="T2KMY2TV9W"
PROFILE="${NOOK_NOTARY_PROFILE:-nook}"
LOCAL=0
[ "${1:-}" = "--local-signing" ] && LOCAL=1
cd "$PROJECT_DIR"

[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first." >&2; exit 1; }
# The active gh account may belong to another project: use olehmrvz's token for this script only.
export GH_TOKEN="$(gh auth token --user olehmrvz)"
# Only what is on main (stable) goes out to every installed copy: push develop:main first.
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
  || { echo "HEAD is not origin/main: merge and push to main first; release cancelled." >&2; exit 1; }

if [ $LOCAL = 1 ]; then
  IDENTITY="Nook Local Signing" STAMP=0
else
  STAMP=1
  IDENTITY="$(security find-identity -v -p codesigning | awk -v team="($TEAM)\"" \
    '/"Developer ID Application: / && index($0, team) { print $2; exit }')"
  [ -n "$IDENTITY" ] \
    || { echo "No Developer ID Application certificate of team $TEAM in the keychain; release cancelled." >&2; exit 1; }
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || { echo "No notary credentials \"$PROFILE\" (docs/DEVELOPMENT.md → Releases); release cancelled." >&2; exit 1; }
fi
NOOK_SIGN_IDENTITY="$IDENTITY" NOOK_TIMESTAMP=$STAMP "$PROJECT_DIR/install.sh" --build-only
APP="$PROJECT_DIR/.build/Nook.app"
# The updater accepts only builds signed like the installed ones: never publish an ad-hoc build.
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
if [ $LOCAL = 1 ]; then
  [[ "$SIGNATURE" == *"Authority=Nook Local Signing"* ]] \
    || { echo "Not signed with \"Nook Local Signing\" (run make-cert.sh); release cancelled." >&2; exit 1; }
else
  [[ "$SIGNATURE" == *"Authority=Developer ID Application:"* && "$SIGNATURE" == *"TeamIdentifier=$TEAM"* ]] \
    || { echo "Not signed with Nook's Developer ID ($TEAM); release cancelled." >&2; exit 1; }
fi

BUILD_NUMBER="$(git rev-list --count HEAD)"
TAG="v$BUILD_NUMBER"
ZIP="$PROJECT_DIR/.build/Nook.zip"
DMG="$PROJECT_DIR/.build/Nook.dmg"
rm -f "$ZIP" "$DMG"

# Sends a file to Apple's notary service and waits (usually a few minutes); prints Apple's log on rejection.
notarize() {
  local result="$PROJECT_DIR/.build/notary.json"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json > "$result" || true
  if [ "$(plutil -extract status raw -o - "$result" 2>/dev/null)" != "Accepted" ]; then
    echo "Notarization of $(basename "$1") failed:" >&2
    cat "$result" >&2
    local id; id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
    [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    exit 1
  fi
}

ASSETS=("$ZIP")
if [ $LOCAL = 0 ]; then
  # The app first: its ticket is stapled into Nook.app, so it opens without a network check too.
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  xcrun stapler staple -q "$APP"
  # A disk image with an Applications link: the usual drag-and-drop install.
  DMG_DIR="$PROJECT_DIR/.build/dmg"
  rm -rf "$DMG_DIR"
  mkdir -p "$DMG_DIR"
  ditto "$APP" "$DMG_DIR/Nook.app"
  ln -s /Applications "$DMG_DIR/Applications"
  # The window's picture and layout from dmg/make-assets.sh (committed): a dark room lit from the notch, glowing
  # chevrons from Nook to Applications. The layout finds the picture by volume name and path, so the name stays
  # "Nook" and the file system HFS+. Without them the image opens as a plain Finder window.
  if [ -f "$PROJECT_DIR/dmg/DS_Store" ] && [ -f "$PROJECT_DIR/dmg/background.tiff" ]; then
    mkdir -p "$DMG_DIR/.background"
    cp "$PROJECT_DIR/dmg/background.tiff" "$DMG_DIR/.background/background.tiff"
    cp "$PROJECT_DIR/dmg/DS_Store" "$DMG_DIR/.DS_Store"
  else
    echo "No DMG layout (dmg/DS_Store, dmg/background.tiff): the window stays plain. Run dmg/make-assets.sh and commit them." >&2
  fi
  # The disk's own icon (window title, path bar, Desktop): .VolumeIcon.icns plus the volume's custom-icon flag.
  # hdiutil does not carry the flag over from the folder, so the image is made writable, flagged, then compressed.
  cp "$APP/Contents/Resources/AppIcon.icns" "$DMG_DIR/.VolumeIcon.icns"
  RW="$PROJECT_DIR/.build/Nook-rw.dmg"
  MOUNT="$PROJECT_DIR/.build/dmg-mount"
  rm -rf "$RW" "$MOUNT"
  hdiutil create -quiet -volname Nook -srcfolder "$DMG_DIR" -fs HFS+ -format UDRW -ov "$RW"
  mkdir -p "$MOUNT"
  hdiutil attach -quiet -readwrite -noverify -noautoopen -nobrowse -mountpoint "$MOUNT" "$RW"
  SetFile -a C "$MOUNT" && rm -rf "$MOUNT/.fseventsd" \
    || { hdiutil detach -quiet "$MOUNT"; echo "Could not set the disk icon; release cancelled." >&2; exit 1; }
  hdiutil detach -quiet "$MOUNT"
  hdiutil convert -quiet "$RW" -format UDZO -ov -o "$DMG"
  rm -rf "$DMG_DIR" "$RW" "$MOUNT"
  codesign --sign "$IDENTITY" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple -q "$DMG"
  # What a downloaded copy meets: Gatekeeper must accept both as notarized.
  spctl --assess --type execute "$APP" && spctl --assess --type open --context context:primary-signature "$DMG" \
    || { echo "Gatekeeper rejects the notarized build; release cancelled." >&2; exit 1; }
  ASSETS+=("$DMG")
  rm -f "$ZIP"
fi
# The updater downloads Nook.zip: for a notarized release it holds the stapled app.
ditto -c -k --keepParent "$APP" "$ZIP"

# Tags of earlier releases are made on GitHub: fetch them for the change list.
git fetch -q --tags origin
PREVIOUS="$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null || true)"
PREVIOUS_BODY="$(gh release view --repo "$REPO" --json body -q .body 2>/dev/null || true)"
NOTES="$(git log --pretty='- %s' ${PREVIOUS:+$PREVIOUS..}HEAD | head -30)"
if [ $LOCAL = 1 ]; then
  SIGNED="Signed with \"Nook Local Signing\" (SHA-1 76A699582536149BB53212178F4A1B2A2DC15CC1), not notarized."
else
  SIGNED="Signed with Developer ID (team $TEAM) and notarized by Apple."
  # The first Developer ID release changes the signature that macOS tied the permissions to.
  [[ "$PREVIOUS_BODY" == *"and notarized by Apple."* ]] || SIGNED="$SIGNED

**After this update:** macOS ties permissions to the app's signature, and this release has a new one.
Open System Settings → Privacy & Security → **Full Disk Access** and **Accessibility**, turn Nook off and on
again (notification and call islands, Focus and the volume keys need them). Calendar, Contacts and similar
permissions may be asked again."
fi
NOTES="$NOTES

$SIGNED
SHA-256:"
for FILE in "${ASSETS[@]}"; do NOTES="$NOTES
- $(basename "$FILE"): $(shasum -a 256 "$FILE" | cut -d' ' -f1)"; done
gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO" --target "$(git rev-parse HEAD)" \
  --title "Nook 1.$BUILD_NUMBER" --notes "$NOTES"
echo "Released $TAG: installed copies offer it within 6 hours (or menu → Updates → Check now)."
