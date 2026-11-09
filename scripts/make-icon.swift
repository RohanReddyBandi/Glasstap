// Draws Glasstap's app icon and writes every size macOS needs into the asset catalog.
//
//   swift scripts/make-icon.swift
//
// The design: a blue squircle with a glass screen on it, and a fingertip ripple where a
// pinch or tap lands. Drawn from plain shapes (SF Symbols' license doesn't allow use in app icons).

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconSet = root.appendingPathComponent("Glasstap/Assets.xcassets/AppIcon.appiconset")

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // macOS icon grid: 824 pt body inset 100 pt, continuous-corner radius ~185.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    // Soft drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(NSColor(red: 0.12, green: 0.2, blue: 0.62, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let colors = [
        NSColor(red: 0.25, green: 0.52, blue: 1.0, alpha: 1).cgColor,
        NSColor(red: 0.11, green: 0.2, blue: 0.66, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Top sheen.
    let sheen = [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
    let sheenGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheen, locations: [0, 1])!
    ctx.drawLinearGradient(sheenGradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()

    // The glass screen.
    let screen = CGRect(x: 232 * s, y: 330 * s, width: 560 * s, height: 384 * s)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 44 * s, cornerHeight: 44 * s, transform: nil)
    ctx.addPath(screenPath)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.13).cgColor)
    ctx.fillPath()
    ctx.addPath(screenPath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
    ctx.setLineWidth(26 * s)
    ctx.strokePath()

    // Stand under the screen.
    let stand = CGRect(x: 432 * s, y: 250 * s, width: 160 * s, height: 26 * s)
    ctx.addPath(CGPath(roundedRect: stand, cornerWidth: 13 * s, cornerHeight: 13 * s, transform: nil))
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
    ctx.fillPath()

    // Ripple where the touch lands.
    let center = CGPoint(x: 604 * s, y: 486 * s)
    for (radius, width, alpha) in [(150.0, 14.0, 0.32), (100.0, 18.0, 0.62)] {
        ctx.addEllipse(in: CGRect(x: center.x - radius * s, y: center.y - radius * s, width: radius * 2 * s, height: radius * 2 * s))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        ctx.setLineWidth(width * s)
        ctx.strokePath()
    }
    ctx.addEllipse(in: CGRect(x: center.x - 50 * s, y: center.y - 50 * s, width: 100 * s, height: 100 * s))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

var images: [[String: String]] = []
for (points, scale) in sizes {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let data = drawIcon(size: CGFloat(pixels)).representation(using: .png, properties: [:])!
    try data.write(to: iconSet.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appendingPathComponent("Contents.json"))
let catalog = iconSet.deletingLastPathComponent().appendingPathComponent("Contents.json")
try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.data(using: .utf8)!.write(to: catalog)
print("Wrote \(sizes.count) icons to \(iconSet.path)")
