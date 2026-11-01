import AppKit
import Foundation
import ImageIO

// A reproducible vector icon, generated locally without downloaded assets.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift <output.icns>\n", stderr)
    exit(2)
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

func sparkle(center: CGPoint, radius: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: center.x, y: center.y + radius))
    path.curve(
        to: CGPoint(x: center.x + radius, y: center.y),
        controlPoint1: CGPoint(x: center.x + radius * 0.22, y: center.y + radius * 0.22),
        controlPoint2: CGPoint(x: center.x + radius * 0.22, y: center.y + radius * 0.22)
    )
    path.curve(
        to: CGPoint(x: center.x, y: center.y - radius),
        controlPoint1: CGPoint(x: center.x + radius * 0.22, y: center.y - radius * 0.22),
        controlPoint2: CGPoint(x: center.x + radius * 0.22, y: center.y - radius * 0.22)
    )
    path.curve(
        to: CGPoint(x: center.x - radius, y: center.y),
        controlPoint1: CGPoint(x: center.x - radius * 0.22, y: center.y - radius * 0.22),
        controlPoint2: CGPoint(x: center.x - radius * 0.22, y: center.y - radius * 0.22)
    )
    path.curve(
        to: CGPoint(x: center.x, y: center.y + radius),
        controlPoint1: CGPoint(x: center.x - radius * 0.22, y: center.y + radius * 0.22),
        controlPoint2: CGPoint(x: center.x - radius * 0.22, y: center.y + radius * 0.22)
    )
    path.close()
    color.setFill()
    path.fill()
}

func renderIcon(pixels: Int) throws -> CGImage {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "MacTools.Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create icon bitmap."])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let background = NSBezierPath(roundedRect: NSRect(x: 86, y: 86, width: 852, height: 852), xRadius: 192, yRadius: 192)
    NSGradient(starting: color(42, 83, 64), ending: color(16, 43, 36))?.draw(in: background, angle: -90)

    let drive = NSBezierPath(roundedRect: NSRect(x: 238, y: 286, width: 548, height: 364), xRadius: 60, yRadius: 60)
    color(245, 245, 229).setFill()
    drive.fill()

    color(216, 223, 202).setFill()
    NSBezierPath(roundedRect: NSRect(x: 238, y: 286, width: 548, height: 124), xRadius: 60, yRadius: 60).fill()
    NSBezierPath(rect: NSRect(x: 238, y: 348, width: 548, height: 62)).fill()

    color(42, 83, 64).setFill()
    NSBezierPath(roundedRect: NSRect(x: 298, y: 334, width: 210, height: 24), xRadius: 12, yRadius: 12).fill()
    NSBezierPath(ovalIn: NSRect(x: 690, y: 328, width: 36, height: 36)).fill()

    sparkle(center: CGPoint(x: 700, y: 720), radius: 108, color: color(199, 235, 145))
    sparkle(center: CGPoint(x: 358, y: 752), radius: 48, color: color(199, 235, 145))

    guard let image = bitmap.cgImage else {
        throw NSError(domain: "MacTools.Icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to render icon."])
    }
    return image
}

let sizes = [16, 32, 128, 256, 512]
guard let encoder = CGImageDestinationCreateWithURL(destination as CFURL, "com.apple.icns" as CFString, sizes.count * 2, nil) else {
    throw NSError(domain: "MacTools.Icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to create icon encoder."])
}
for size in sizes {
    for scale in [1, 2] {
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale
        ]
        CGImageDestinationAddImage(encoder, try renderIcon(pixels: size * scale), properties as CFDictionary)
    }
}
guard CGImageDestinationFinalize(encoder) else {
    throw NSError(domain: "MacTools.Icon", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to save icon."])
}
