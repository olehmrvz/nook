#!/bin/bash
# Publishes the current commit as a GitHub release. Every installed Nook checks the latest release every
# 6 hours, downloads it and installs it by itself (Sources/Updater.swift). Run from a clean tree.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="olehmrvz/nook"
cd "$PROJECT_DIR"

[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first." >&2; exit 1; }
# The active gh account may belong to another project: use olehmrvz's token for this script only.
export GH_TOKEN="$(gh auth token --user olehmrvz)"
# Only what is on main (stable) goes out to every installed copy: push develop:main first.
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
  || { echo "HEAD is not origin/main: merge and push to main first; release cancelled." >&2; exit 1; }
"$PROJECT_DIR/install.sh" --build-only
APP="$PROJECT_DIR/.build/Nook.app"
# The updater accepts only builds signed like the installed ones: never publish an ad-hoc build.
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIGNATURE" == *"Authority=Nook Local Signing"* ]] \
  || { echo "Not signed with \"Nook Local Signing\" (run make-cert.sh); release cancelled." >&2; exit 1; }

BUILD_NUMBER="$(git rev-list --count HEAD)"
TAG="v$BUILD_NUMBER"
ZIP="$PROJECT_DIR/.build/Nook.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# Tags of earlier releases are made on GitHub: fetch them for the change list.
git fetch -q --tags origin
PREVIOUS="$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null || true)"
NOTES="$(git log --pretty='- %s' ${PREVIOUS:+$PREVIOUS..}HEAD | head -30)"
NOTES="$NOTES

SHA-256 of Nook.zip: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)
Signing certificate (SHA-1): 76A699582536149BB53212178F4A1B2A2DC15CC1"
gh release create "$TAG" "$ZIP" --repo "$REPO" --target "$(git rev-parse HEAD)" \
  --title "Nook 1.$BUILD_NUMBER" --notes "${NOTES:-Nook 1.$BUILD_NUMBER}"
echo "Released $TAG: installed copies update within 6 hours (or menu → Updates → Check now)."
