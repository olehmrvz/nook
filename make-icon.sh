#!/bin/bash
# Draws the Nook icon (a black N on a lime tile) and writes <out>/AppIcon.icns.
set -euo pipefail
OUT="${1:-.build}"
SET="$OUT/AppIcon.iconset"
mkdir -p "$SET"

cat > "$OUT/icon.swift" <<'SWIFT'
import AppKit
// N «Чистая» (Figma Sandbox, frame 560:2): a heavy N with a chamfered top-left corner and a 45° diagonal, black on
// a lime tile. Points on the 600 grid of the mark's drawing (y down), centred and scaled per size.
let mark: [(CGFloat, CGFloat)] = [(76, 403), (76, 300), (180, 196), (276, 196), (383, 303), (383, 196), (483, 196),
                                  (483, 403), (283, 403), (176, 296), (176, 403)]
let minX = mark.map(\.0).min()!, maxX = mark.map(\.0).max()!, minY = mark.map(\.1).min()!, maxY = mark.map(\.1).max()!
let dir = CommandLine.arguments[1]
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // The macOS grid: an 824 body on a 1024 canvas, with a soft shadow under it.
    let tile = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let body = NSBezierPath(roundedRect: tile, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.03
    shadow.set()
    NSColor(red: 0.78, green: 0.98, blue: 0.3, alpha: 1).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0xE4 / 255, green: 1, blue: 0x8A / 255, alpha: 1),
                        NSColor(red: 0xB4 / 255, green: 0xF2 / 255, blue: 0x2E / 255, alpha: 1)])!.draw(in: body, angle: -45)
    // Small sizes get a bigger letter: at 16 px the mark at full-size proportions is a few pixels high.
    let width = s * (px <= 32 ? 0.66 : 0.55)
    let k = width / (maxX - minX)
    let x0 = (s - width) / 2, y0 = (s - (maxY - minY) * k) / 2
    let n = NSBezierPath()
    for (i, p) in mark.enumerated() {
        let point = NSPoint(x: x0 + (p.0 - minX) * k, y: s - (y0 + (p.1 - minY) * k))
        if i == 0 { n.move(to: point) } else { n.line(to: point) }
    }
    n.close()
    NSColor(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0C / 255, alpha: 1).setFill()
    n.fill()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
}
SWIFT
swift "$OUT/icon.swift" "$SET"
iconutil -c icns "$SET" -o "$OUT/AppIcon.icns"
echo "$OUT/AppIcon.icns"
