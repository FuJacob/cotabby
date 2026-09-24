#!/usr/bin/env swift
import AppKit

/// Generates CoHamster's original vector-drawn artwork at every asset-catalog resolution.
/// This build-time tool owns the paths, not application state: running it from the repo root
/// writes PNGs consumed by the menu, onboarding, settings, and macOS app icon catalogs.
/// The colorful mascot and small menu-bar glyph have separate geometry: details that work on
/// an app icon become visual noise at 18 points. Each drawing still generates all of its scales.
/// Pass `--menu-bar-only` to iterate on the status glyph without rewriting the other artwork.
let assets = URL(fileURLWithPath: "Cotabby/Assets.xcassets", isDirectory: true)
let menuBarOnly = CommandLine.arguments.contains("--menu-bar-only")

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func render(size: Int, dev: Bool = false) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ fill: UInt32) {
        context.setFillColor(color(fill))
        context.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
    }
    func rounded(_ rect: CGRect, radius: CGFloat, fill: UInt32) {
        context.setFillColor(color(fill))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }
    rounded(CGRect(x: 0, y: 0, width: 1024, height: 1024), radius: 210,
            fill: dev ? 0x293A52 : 0x007AFF)
    let fur: UInt32 = 0xF4B65D
    ellipse(164, 577, 252, 252, fur)
    ellipse(608, 577, 252, 252, fur)
    ellipse(219, 626, 140, 144, 0xE98C80)
    ellipse(665, 626, 140, 144, 0xE98C80)
    ellipse(171, 204, 682, 531, fur)
    ellipse(210, 231, 322, 316, 0xFFF2D4)
    ellipse(492, 231, 322, 316, 0xFFF2D4)
    ellipse(260, 366, 119, 81, 0xF2A07D)
    ellipse(645, 366, 119, 81, 0xF2A07D)
    ellipse(332, 487, 58, 72, 0x253246)
    ellipse(634, 487, 58, 72, 0x253246)
    ellipse(470, 380, 84, 58, 0x253246)
    context.setStrokeColor(color(0x253246))
    context.setLineWidth(23)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 512, y: 391))
    context.addLine(to: CGPoint(x: 512, y: 337))
    context.move(to: CGPoint(x: 435, y: 349))
    context.addQuadCurve(to: CGPoint(x: 512, y: 337), control: CGPoint(x: 469, y: 304))
    context.addQuadCurve(to: CGPoint(x: 589, y: 349), control: CGPoint(x: 555, y: 304))
    context.strokePath()
    rounded(CGRect(x: 477, y: 274, width: 70, height: 58), radius: 10, fill: 0xFFFFFF)
    context.setStrokeColor(color(0xEAD8BB))
    context.setLineWidth(5)
    context.move(to: CGPoint(x: 512, y: 277))
    context.addLine(to: CGPoint(x: 512, y: 328))
    context.strokePath()
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

/// Draws directly in the 18-point coordinate space used by `MenuBarStatusLabelView`.
/// A continuous outline leaves the cheeks open, while small ears distinguish the hamster from
/// the round-eared app mascot. Transparent pixels let macOS tint the template in either appearance.
func renderMenuBarIcon(size: Int) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // A top-left origin makes the tiny silhouette easier to tune against a menu-bar preview.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: CGFloat(size) / 18, y: -CGFloat(size) / 18)
    context.setStrokeColor(color(0x000000))
    context.setFillColor(color(0x000000))
    context.setLineWidth(1.35)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    context.move(to: CGPoint(x: 6.6, y: 4.5))
    context.addCurve(to: CGPoint(x: 2.8, y: 6.4),
                     control1: CGPoint(x: 5.8, y: 0.6), control2: CGPoint(x: 1.0, y: 2.4))
    context.addCurve(to: CGPoint(x: 1.6, y: 10.5),
                     control1: CGPoint(x: 2.1, y: 7.6), control2: CGPoint(x: 1.6, y: 8.8))
    context.addCurve(to: CGPoint(x: 9, y: 15.5),
                     control1: CGPoint(x: 1.6, y: 13.8), control2: CGPoint(x: 5.0, y: 15.5))
    context.addCurve(to: CGPoint(x: 16.4, y: 10.5),
                     control1: CGPoint(x: 13.0, y: 15.5), control2: CGPoint(x: 16.4, y: 13.8))
    context.addCurve(to: CGPoint(x: 15.2, y: 6.4),
                     control1: CGPoint(x: 16.4, y: 8.8), control2: CGPoint(x: 15.9, y: 7.6))
    context.addCurve(to: CGPoint(x: 11.4, y: 4.5),
                     control1: CGPoint(x: 17.0, y: 2.4), control2: CGPoint(x: 12.2, y: 0.6))
    context.addQuadCurve(to: CGPoint(x: 6.6, y: 4.5), control: CGPoint(x: 9, y: 3.7))
    context.closePath()
    context.strokePath()

    // Keep facial marks solid and separated; tiny cutouts disappear on non-Retina displays.
    for x: CGFloat in [5.25, 11.25] {
        context.fillEllipse(in: CGRect(x: x, y: 8, width: 1.5, height: 1.75))
    }
    context.move(to: CGPoint(x: 8.1, y: 11.25))
    context.addQuadCurve(to: CGPoint(x: 9.9, y: 11.25), control: CGPoint(x: 9, y: 10.85))
    context.addQuadCurve(to: CGPoint(x: 9, y: 12.55), control: CGPoint(x: 10.25, y: 11.55))
    context.addQuadCurve(to: CGPoint(x: 8.1, y: 11.25), control: CGPoint(x: 7.75, y: 11.55))
    context.fillPath()

    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

for dev in [false, true] where !menuBarOnly {
    let directory = assets.appendingPathComponent(dev ? "AppIconDev.appiconset" : "AppIcon.appiconset")
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        try render(size: size, dev: dev).write(to: directory.appendingPathComponent("\(size).png"))
    }
}
for (name, template, baseSize) in [("CoHamsterLogo", false, 256), ("MenuBarHamsterIcon", true, 18)]
    where !menuBarOnly || template {
    let directory = assets.appendingPathComponent("\(name).imageset")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for scale in 1...3 {
        let filename = name + (scale == 1 ? "" : "@\(scale)x") + ".png"
        let data = template ? renderMenuBarIcon(size: baseSize * scale) : render(size: baseSize * scale)
        try data.write(to: directory.appendingPathComponent(filename))
        images.append(["idiom": "universal", "scale": "\(scale)x", "filename": filename])
    }
    var catalog: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    if template { catalog["properties"] = ["template-rendering-intent": "template"] }
    let data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("Contents.json"))
}
