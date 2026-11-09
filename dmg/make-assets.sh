#!/bin/bash
# Draws the DMG window's background and records its layout; release.sh copies both into Nook.dmg.
#   dmg/background.tiff  the picture (1x and 2x in one file): a dark room lit from the notch, a drop that says what to
#                        do, glowing chevrons from Nook to Applications, a dashed frame where to let go
#   dmg/DS_Store         the Finder layout: icon view, icon size, positions of Nook and Applications, the background
# Run again after changing the picture or the layout, then commit both files (release.sh copies them; without them
# Nook.dmg opens as a plain window). The layout step asks Finder to arrange a scratch disk image, so the first run
# asks once for permission to control Finder. Finder writes the names in black on a window with a background
# picture, in Dark Mode too, so each name sits on a light plate drawn in the picture.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
DEVICE=""
# Detaches only the scratch image this script attached, never a "Nook" volume the person has open.
trap '[ -z "$DEVICE" ] || hdiutil detach -quiet "$DEVICE" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# Window content 640 × 440; icons 128 at y 228, Nook at x 170, Applications at x 470. The bottom 28 pt may hide
# under Finder's path bar (a global Finder setting), so nothing there matters.
cat > "$WORK/background.swift" <<'SWIFT'
import AppKit

// The DMG window's picture: a dark room lit from the notch. Content 640 × 440 pt, y down in the comments,
// AppKit y up in code (flip() converts). Icons (128 pt) centred at (170, 228) and (470, 228).
let width: CGFloat = 640, height: CGFloat = 440
let nookX: CGFloat = 170, appsX: CGFloat = 470, iconY: CGFloat = 228
let lime = NSColor(red: 0xC6 / 255, green: 1, blue: 0x3D / 255, alpha: 1)
let ink = NSColor(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0C / 255, alpha: 1)
func flip(_ y: CGFloat) -> CGFloat { height - y }

func glow(_ center: NSPoint, _ radius: CGFloat, _ color: NSColor, _ alpha: CGFloat, squash: CGFloat = 1) {
    // A soft round light: many stops so the falloff is smooth (no ring), squashed vertically when asked.
    let stops = 12
    var colors: [NSColor] = [], locations: [CGFloat] = []
    for i in 0...stops {
        let t = CGFloat(i) / CGFloat(stops)
        colors.append(color.withAlphaComponent(alpha * exp(-4.2 * t * t)))
        locations.append(t)
    }
    let gradient = NSGradient(colors: colors, atLocations: &locations, colorSpace: .deviceRGB)!
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.scaleX(by: 1, yBy: squash)
    transform.concat()
    gradient.draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: radius, options: [])
    NSGraphicsContext.restoreGraphicsState()
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerX: CGFloat, centerY: CGFloat) {
    let line = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                               .foregroundColor: color])
    let s = line.size()
    line.draw(at: NSPoint(x: centerX - s.width / 2, y: flip(centerY) - s.height / 2))
}

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // The room: near black, a touch lighter at the top so the black drop reads against it.
    NSGradient(colors: [NSColor(red: 0.082, green: 0.082, blue: 0.094, alpha: 1), ink, ink],
               atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // A faint grid of dots, lit where the light falls: brighter near the drop and the icons.
    func light(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        func spot(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ sx: CGFloat = 1) -> CGFloat {
            let dx = (x - cx) / (r * sx), dy = (y - cy) / r
            return exp(-(dx * dx + dy * dy))
        }
        return spot(width / 2, 40, 120, 1.9) + 0.7 * spot(nookX, iconY + 40, 120) + 0.35 * spot(appsX, iconY + 40, 120)
    }
    let step: CGFloat = 16
    var gy = step / 2
    while gy < height {
        var gx = step / 2 + (width.truncatingRemainder(dividingBy: step)) / 2
        while gx < width {
            let l = min(1, light(gx, gy))
            let tint = NSColor(red: 0.78 + 0.22 * (1 - l), green: 1, blue: 0.24 + 0.76 * (1 - l), alpha: 1)
            tint.withAlphaComponent(0.035 + 0.16 * l).setFill()
            NSBezierPath(ovalIn: NSRect(x: gx - 0.9, y: flip(gy) - 0.9, width: 1.8, height: 1.8)).fill()
            gx += step
        }
        gy += step
    }

    // Light on the floor under each icon: tight and bright, not a wash (dim lime turns olive).
    glow(NSPoint(x: nookX, y: flip(iconY + 62)), 84, lime, 0.7, squash: 0.18)
    glow(NSPoint(x: nookX, y: flip(iconY + 4)), 110, lime, 0.14)
    glow(NSPoint(x: appsX, y: flip(iconY + 62)), 84, NSColor(red: 0.62, green: 0.82, blue: 1, alpha: 1), 0.36, squash: 0.18)

    // The drop hanging from the notch, as Nook draws it: pure black, ears curving into the top edge.
    let dropW: CGFloat = 292, dropH: CGFloat = 54, ear: CGFloat = 11, r: CGFloat = 22
    let left = width / 2 - dropW / 2, right = width / 2 + dropW / 2
    let drop = NSBezierPath()
    drop.move(to: NSPoint(x: left - ear, y: flip(0)))
    drop.curve(to: NSPoint(x: left, y: flip(ear)), controlPoint1: NSPoint(x: left - ear * 0.35, y: flip(0)),
               controlPoint2: NSPoint(x: left, y: flip(ear * 0.35)))
    drop.line(to: NSPoint(x: left, y: flip(dropH - r)))
    drop.curve(to: NSPoint(x: left + r, y: flip(dropH)), controlPoint1: NSPoint(x: left, y: flip(dropH - r * 0.45)),
               controlPoint2: NSPoint(x: left + r * 0.45, y: flip(dropH)))
    drop.line(to: NSPoint(x: right - r, y: flip(dropH)))
    drop.curve(to: NSPoint(x: right, y: flip(dropH - r)), controlPoint1: NSPoint(x: right - r * 0.45, y: flip(dropH)),
               controlPoint2: NSPoint(x: right, y: flip(dropH - r * 0.45)))
    drop.line(to: NSPoint(x: right, y: flip(ear)))
    drop.curve(to: NSPoint(x: right + ear, y: flip(0)), controlPoint1: NSPoint(x: right, y: flip(ear * 0.35)),
               controlPoint2: NSPoint(x: right + ear * 0.35, y: flip(0)))
    drop.close()
    NSGraphicsContext.saveGraphicsState()
    let halo = NSShadow()
    halo.shadowColor = lime.withAlphaComponent(0.42)
    halo.shadowBlurRadius = 44 * scale
    halo.shadowOffset = NSSize(width: 0, height: -10 * scale)
    halo.set()
    NSColor.black.setFill()
    drop.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    let rim = NSShadow()
    rim.shadowColor = lime.withAlphaComponent(0.9)
    rim.shadowBlurRadius = 9 * scale
    rim.shadowOffset = NSSize(width: 0, height: -2 * scale)
    rim.set()
    NSColor.black.setFill()
    drop.fill()
    NSGraphicsContext.restoreGraphicsState()
    // A hairline of light along the drop's lower edge, like the glow rising inside the panel.
    NSGraphicsContext.saveGraphicsState()
    drop.addClip()
    glow(NSPoint(x: width / 2, y: flip(dropH + 4)), 140, lime, 0.38, squash: 0.16)
    NSGraphicsContext.restoreGraphicsState()

    // In the drop: a lime arrow badge and the one instruction.
    let badge = NSBezierPath(roundedRect: NSRect(x: left + 18, y: flip(dropH / 2 + 2) - 13, width: 26, height: 26),
                             xRadius: 8, yRadius: 8)
    lime.setFill()
    badge.fill()
    let bx = left + 31, by = flip(dropH / 2 + 2)
    let tick = NSBezierPath()
    tick.move(to: NSPoint(x: bx - 6, y: by))
    tick.line(to: NSPoint(x: bx + 5, y: by))
    tick.move(to: NSPoint(x: bx + 1, y: by + 4.5))
    tick.line(to: NSPoint(x: bx + 5.5, y: by))
    tick.line(to: NSPoint(x: bx + 1, y: by - 4.5))
    tick.lineWidth = 2.4
    tick.lineCapStyle = .round
    tick.lineJoinStyle = .round
    ink.setStroke()
    tick.stroke()
    let title = NSAttributedString(string: "Drag Nook to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.white])
    title.draw(at: NSPoint(x: left + 56, y: flip(dropH / 2 + 2) - title.size().height / 2))

    // The way: chevrons cut at 45° like the N, brighter towards Applications, each with its own glow.
    let start: CGFloat = 262, end: CGFloat = 376, count = 5
    for i in 0..<count {
        let t = CGFloat(i) / CGFloat(count - 1)
        let x = start + (end - start) * t, y = flip(iconY - 4)
        let chevron = NSBezierPath()
        let h: CGFloat = 11, w: CGFloat = 4.5, depth: CGFloat = 11
        chevron.move(to: NSPoint(x: x - depth / 2, y: y + h))
        chevron.line(to: NSPoint(x: x - depth / 2 + w, y: y + h))
        chevron.line(to: NSPoint(x: x + depth / 2 + w, y: y))
        chevron.line(to: NSPoint(x: x - depth / 2 + w, y: y - h))
        chevron.line(to: NSPoint(x: x - depth / 2, y: y - h))
        chevron.line(to: NSPoint(x: x + depth / 2, y: y))
        chevron.close()
        NSGraphicsContext.saveGraphicsState()
        let shine = NSShadow()
        shine.shadowColor = lime.withAlphaComponent(0.35 + 0.55 * t)
        shine.shadowBlurRadius = 12 * scale
        shine.shadowOffset = .zero
        shine.set()
        lime.withAlphaComponent(0.38 + 0.62 * t).setFill()
        chevron.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Where to let go: a dashed frame around Applications.
    // Its bottom edge runs through the name's plate, like a legend.
    let zoneTop = iconY - 82, zoneBottom = iconY + 83.5
    let zone = NSBezierPath(roundedRect: NSRect(x: appsX - 86, y: flip(zoneBottom), width: 172, height: zoneBottom - zoneTop),
                            xRadius: 34, yRadius: 34)
    zone.lineWidth = 1.5
    zone.setLineDash([7, 6], count: 2, phase: 0)
    NSColor(white: 1, alpha: 0.22).setStroke()
    zone.stroke()

    // Plates under the names: Finder writes them in black on any picture, in Dark Mode too.
    // Name centre = icon centre + 83.5 pt at icon size 128, text size 13. Measured, wide enough for "Nook.app"
    // (Finder → Show all filename extensions), 14.5 pt of plate on each side.
    let nameY = iconY + 83.5
    func plate(_ name: String) -> CGFloat {
        (NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 13)]).size().width + 29).rounded()
    }
    for (x, w, color) in [(nookX, plate("Nook.app"), lime), (appsX, plate("Applications"), NSColor(white: 0.93, alpha: 1))] {
        let plate = NSBezierPath(roundedRect: NSRect(x: x - w / 2, y: flip(nameY) - 11, width: w, height: 22),
                                 xRadius: 11, yRadius: 11)
        NSGraphicsContext.saveGraphicsState()
        let lift = NSShadow()
        lift.shadowColor = color.withAlphaComponent(0.35)
        lift.shadowBlurRadius = 14 * scale
        lift.shadowOffset = .zero
        lift.set()
        color.setFill()
        plate.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // After the drag.
    text("Then open Nook. It lives in your notch.", size: 12.5, weight: .medium,
             color: NSColor(white: 1, alpha: 0.42), centerX: width / 2, centerY: 382)

    NSGraphicsContext.restoreGraphicsState()

    // Dither: ±1 level of noise, so the glows do not band on 8-bit colour.
    if let data = rep.bitmapData {
        var seed: UInt32 = 2463534242
        for i in 0..<(rep.pixelsWide * rep.pixelsHigh) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let noise = Int(seed % 3) - 1
            for c in 0..<3 {
                let p = i * 4 + c
                data[p] = UInt8(max(0, min(255, Int(data[p]) + noise)))
            }
        }
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let dir = CommandLine.arguments[1]
render(scale: 1, to: dir + "/background.png")
render(scale: 2, to: dir + "/background@2x.png")
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
# Bounds include the 32 pt title bar: 640 × (440 + 32).
osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Nook"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 592}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 128
        set text size of options to 13
        set label position of options to bottom
        set background picture of options to file ".background:background.tiff"
        set position of item "Nook.app" of container window to {170, 228}
        set position of item "Applications" of container window to {470, 228}
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
