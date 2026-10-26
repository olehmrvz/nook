#!/bin/bash
# Draws the Nook icon (dark tile with a glowing notch) and writes <out>/AppIcon.icns.
set -euo pipefail
OUT="${1:-.build}"
SET="$OUT/AppIcon.iconset"
mkdir -p "$SET"

cat > "$OUT/icon.swift" <<'SWIFT'
import AppKit
let dir = CommandLine.arguments[1]
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let bg = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(white: 0.2, alpha: 1), NSColor(white: 0.06, alpha: 1)])!.draw(in: bg, angle: -90)
    let pill = NSRect(x: s * 0.3, y: s * 0.62, width: s * 0.4, height: s * 0.13)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: pill, xRadius: s * 0.065, yRadius: s * 0.065).fill()
    NSColor(red: 1, green: 0.62, blue: 0.2, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: s * 0.6, y: s * 0.655, width: s * 0.06, height: s * 0.06)).fill()
    NSColor(white: 1, alpha: 0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.33, y: s * 0.665, width: s * 0.06, height: s * 0.04),
                 xRadius: s * 0.01, yRadius: s * 0.01).fill()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
}
SWIFT
swift "$OUT/icon.swift" "$SET"
iconutil -c icns "$SET" -o "$OUT/AppIcon.icns"
echo "$OUT/AppIcon.icns"
