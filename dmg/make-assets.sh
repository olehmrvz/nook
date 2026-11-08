#!/bin/bash
# Draws the DMG window's background and records its layout; release.sh copies both into Nook.dmg.
#   dmg/background.tiff  the picture (1x and 2x in one file): a lime tile like the icon, an arrow, one line of help
#   dmg/DS_Store         the Finder layout: icon view, icon size, positions of Nook and Applications, the background
# Run again after changing the picture or the layout, then commit both files (release.sh copies them; without them
# Nook.dmg opens as a plain window). The layout step asks Finder to arrange a scratch disk image, so the first run
# asks once for permission to control Finder. Finder keeps black labels on a window with a
# background picture, whatever the appearance, so the picture is light.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
DEVICE=""
# Detaches only the scratch image this script attached, never a "Nook" volume the person has open.
trap '[ -z "$DEVICE" ] || hdiutil detach -quiet "$DEVICE" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# Window content 600 × 400; icons 128 at y 200, Nook on the left, Applications on the right.
cat > "$WORK/background.swift" <<'SWIFT'
import AppKit
let width: CGFloat = 600, height: CGFloat = 400
let ink = NSColor(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0C / 255, alpha: 1)
for (name, scale) in [("background.png", 1), ("background@2x.png", 2)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let all = NSRect(x: 0, y: 0, width: width, height: height)
    // The icon's tile: the same two limes at the same angle.
    NSGradient(colors: [NSColor(red: 0xE4 / 255, green: 1, blue: 0x8A / 255, alpha: 1),
                        NSColor(red: 0xB4 / 255, green: 0xF2 / 255, blue: 0x2E / 255, alpha: 1)])!.draw(in: all, angle: -45)
    // Soft light pads under the icons and their names, so both stand out from the lime.
    for x in [150.0, 450.0] {
        let pad = NSBezierPath(roundedRect: NSRect(x: x - 86, y: height - 306, width: 172, height: 190),
                               xRadius: 38, yRadius: 38)
        NSColor(white: 1, alpha: 0.28).setFill()
        pad.fill()
    }
    // The arrow in the letter's own geometry: a straight shaft, a head cut at 45°.
    let y = height - 200, left: CGFloat = 250, right: CGFloat = 352, half: CGFloat = 7, head: CGFloat = 22
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: left, y: y - half))
    arrow.line(to: NSPoint(x: right - head, y: y - half))
    arrow.line(to: NSPoint(x: right - head, y: y - half - 14))
    arrow.line(to: NSPoint(x: right, y: y))
    arrow.line(to: NSPoint(x: right - head, y: y + half + 14))
    arrow.line(to: NSPoint(x: right - head, y: y + half))
    arrow.line(to: NSPoint(x: left, y: y + half))
    arrow.close()
    ink.setFill()
    arrow.fill()
    func text(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, top: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                         .foregroundColor: ink.withAlphaComponent(alpha), .paragraphStyle: style]
        let line = NSAttributedString(string: string, attributes: attributes)
        line.draw(in: NSRect(x: 0, y: height - top - line.size().height, width: width, height: line.size().height))
    }
    text("Drag Nook to Applications", size: 22, weight: .bold, alpha: 1, top: 44)
    text("Then open it once: Nook lives in the notch.", size: 13, weight: .medium, alpha: 0.62, top: 334)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name))
}
SWIFT
swift "$WORK/background.swift" "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$DIR/background.tiff" >/dev/null

# The layout: a scratch image with the same volume name and file system as Nook.dmg, arranged by Finder.
[ ! -e "/Volumes/Nook" ] || { echo "A volume named Nook is mounted: eject it first." >&2; exit 1; }
SRC="$WORK/src"
mkdir -p "$SRC/.background" "$SRC/Nook.app/Contents"
cp "$DIR/background.tiff" "$SRC/.background/background.tiff"
ln -s /Applications "$SRC/Applications"
hdiutil create -quiet -volname Nook -srcfolder "$SRC" -fs HFS+ -format UDRW -ov "$WORK/layout.dmg"
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/layout.dmg" | awk 'NR == 1 { print $1 }')"
osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Nook"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 548}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 128
        set text size of options to 13
        set background picture of options to file ".background:background.tiff"
        set position of item "Nook.app" of container window to {150, 200}
        set position of item "Applications" of container window to {450, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
sync
sleep 1
cp "/Volumes/Nook/.DS_Store" "$DIR/DS_Store"
echo "$DIR/background.tiff"
echo "$DIR/DS_Store"
