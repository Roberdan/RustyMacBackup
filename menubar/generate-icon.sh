#!/bin/bash
set -euo pipefail

# Generate a colorful app icon for RustyMacBackup using AppKit

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICONSET="${SCRIPT_DIR}/AppIcon.iconset"
ICNS="${SCRIPT_DIR}/AppIcon.icns"
SWIFT_FILE="/tmp/gen_icon_rmb.swift"

rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"

cat > "${SWIFT_FILE}" << 'SWIFT'
import Cocoa

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }
    let s = size
    let pad = s * 0.04

    // Rounded rectangle background — vivid blue gradient
    let bgRect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bgColors = [
        CGColor(red: 0.14, green: 0.39, blue: 0.92, alpha: 1.0),
        CGColor(red: 0.08, green: 0.24, blue: 0.72, alpha: 1.0),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: s/2, y: s), end: CGPoint(x: s/2, y: 0), options: [])
    }
    ctx.restoreGState()

    // Hard drive body — white/light blue rounded rect
    let driveW = s * 0.64
    let driveH = s * 0.38
    let driveX = (s - driveW) / 2
    let driveY = s * 0.15
    let driveRect = CGRect(x: driveX, y: driveY, width: driveW, height: driveH)
    let drivePath = CGPath(roundedRect: driveRect, cornerWidth: s * 0.04, cornerHeight: s * 0.04, transform: nil)
    ctx.addPath(drivePath)
    ctx.setFillColor(CGColor(red: 0.94, green: 0.96, blue: 1.0, alpha: 0.95))
    ctx.fillPath()

    // Drive slot line
    let lineY = driveY + driveH * 0.28
    ctx.setStrokeColor(CGColor(red: 0.58, green: 0.77, blue: 0.98, alpha: 1.0))
    ctx.setLineWidth(max(s * 0.008, 1))
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: driveX + s * 0.05, y: lineY))
    ctx.addLine(to: CGPoint(x: driveX + driveW - s * 0.05, y: lineY))
    ctx.strokePath()

    // Drive LED — green dot
    let ledR = s * 0.02
    ctx.setFillColor(CGColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(
        x: driveX + driveW - s * 0.08, y: driveY + s * 0.04,
        width: ledR * 2, height: ledR * 2))

    // Shield with checkmark — green, upper portion
    let shieldCX = s * 0.5
    let shieldTop = s * 0.85
    let shieldW = s * 0.26
    let shieldH = s * 0.38

    let shieldPath = CGMutablePath()
    shieldPath.move(to: CGPoint(x: shieldCX, y: shieldTop))
    shieldPath.addLine(to: CGPoint(x: shieldCX + shieldW/2, y: shieldTop - shieldH * 0.2))
    shieldPath.addLine(to: CGPoint(x: shieldCX + shieldW/2, y: shieldTop - shieldH * 0.65))
    shieldPath.addQuadCurve(
        to: CGPoint(x: shieldCX, y: shieldTop - shieldH),
        control: CGPoint(x: shieldCX + shieldW * 0.3, y: shieldTop - shieldH * 0.9))
    shieldPath.addQuadCurve(
        to: CGPoint(x: shieldCX - shieldW/2, y: shieldTop - shieldH * 0.65),
        control: CGPoint(x: shieldCX - shieldW * 0.3, y: shieldTop - shieldH * 0.9))
    shieldPath.addLine(to: CGPoint(x: shieldCX - shieldW/2, y: shieldTop - shieldH * 0.2))
    shieldPath.closeSubpath()

    // Shield gradient: green
    ctx.saveGState()
    ctx.addPath(shieldPath)
    ctx.clip()
    let shieldColors = [
        CGColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 0.95),
        CGColor(red: 0.09, green: 0.64, blue: 0.29, alpha: 0.95),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: shieldColors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
            start: CGPoint(x: shieldCX, y: shieldTop),
            end: CGPoint(x: shieldCX, y: shieldTop - shieldH),
            options: [])
    }
    ctx.restoreGState()

    // Checkmark inside shield — white
    let checkScale = shieldH * 0.22
    let checkCX = shieldCX
    let checkCY = shieldTop - shieldH * 0.5
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(max(s * 0.025, 2))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: checkCX - checkScale * 0.7, y: checkCY))
    ctx.addLine(to: CGPoint(x: checkCX - checkScale * 0.1, y: checkCY - checkScale * 0.6))
    ctx.addLine(to: CGPoint(x: checkCX + checkScale * 0.8, y: checkCY + checkScale * 0.5))
    ctx.strokePath()

    // Gold sync arrows — left and right
    ctx.setStrokeColor(CGColor(red: 1.0, green: 0.78, blue: 0.17, alpha: 0.85))
    ctx.setLineWidth(max(s * 0.018, 1.5))
    ctx.setLineCap(.round)
    // Left arrow arc
    let arrowY = s * 0.34
    ctx.addArc(center: CGPoint(x: s * 0.5, y: arrowY),
               radius: s * 0.37, startAngle: .pi * 0.85, endAngle: .pi * 0.65, clockwise: true)
    ctx.strokePath()
    // Right arrow arc
    ctx.addArc(center: CGPoint(x: s * 0.5, y: arrowY),
               radius: s * 0.37, startAngle: .pi * 0.15, endAngle: .pi * (-0.05), clockwise: true)
    ctx.strokePath()

    img.unlockFocus()
    return img
}

func savePNG(_ image: NSImage, to path: String, size: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                pixelsWide: size, pixelsHigh: size,
                                bitsPerSample: 8, samplesPerPixel: 4,
                                hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

let outputDir = CommandLine.arguments[1]
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, name) in sizes {
    let icon = drawIcon(size: CGFloat(size))
    savePNG(icon, to: "\(outputDir)/\(name)", size: size)
}
print("All icon sizes generated")
SWIFT

# Compile and run the icon generator
swiftc -O -framework Cocoa "${SWIFT_FILE}" -o /tmp/gen_icon_rmb
/tmp/gen_icon_rmb "${ICONSET}"

# Build .icns
iconutil -c icns "${ICONSET}" -o "${ICNS}"
echo "Icon created: ${ICNS}"

# Cleanup
rm -rf "${ICONSET}" "${SWIFT_FILE}" /tmp/gen_icon_rmb
