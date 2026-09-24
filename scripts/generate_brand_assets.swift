#!/usr/bin/env swift
import AppKit

/// Generates CoHamster's original vector-drawn artwork at every asset-catalog resolution.
/// This build-time tool owns the paths, not application state: running it from the repo root
/// writes PNGs consumed by the menu, onboarding, settings, and macOS app icon catalogs.
/// Keeping one normalized drawing avoids divergent hand-edited small/large icons.
let assets = URL(fileURLWithPath: "Cotabby/Assets.xcassets", isDirectory: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func render(size: Int, template: Bool = false, dev: Bool = false) -> Data {
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
    if !template {
        rounded(CGRect(x: 0, y: 0, width: 1024, height: 1024), radius: 210,
                fill: dev ? 0x293A52 : 0x007AFF)
    }
    let fur: UInt32 = template ? 0x000000 : 0xF4B65D
    ellipse(164, 577, 252, 252, fur)
    ellipse(608, 577, 252, 252, fur)
    if !template {
        ellipse(219, 626, 140, 144, 0xE98C80)
        ellipse(665, 626, 140, 144, 0xE98C80)
    }
    ellipse(171, 204, 682, 531, fur)
    if !template {
        ellipse(210, 231, 322, 316, 0xFFF2D4)
        ellipse(492, 231, 322, 316, 0xFFF2D4)
        ellipse(260, 366, 119, 81, 0xF2A07D)
        ellipse(645, 366, 119, 81, 0xF2A07D)
    }
    // Knockouts make the monochrome status glyph legible in either macOS appearance.
    context.setBlendMode(template ? .clear : .normal)
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
    context.setBlendMode(.normal)
    if !template {
        rounded(CGRect(x: 477, y: 274, width: 70, height: 58), radius: 10, fill: 0xFFFFFF)
        context.setStrokeColor(color(0xEAD8BB))
        context.setLineWidth(5)
        context.move(to: CGPoint(x: 512, y: 277))
        context.addLine(to: CGPoint(x: 512, y: 328))
        context.strokePath()
    }
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

for dev in [false, true] {
    let directory = assets.appendingPathComponent(dev ? "AppIconDev.appiconset" : "AppIcon.appiconset")
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        try render(size: size, dev: dev).write(to: directory.appendingPathComponent("\(size).png"))
    }
}
for (name, template, baseSize) in [("CoHamsterLogo", false, 256), ("MenuBarHamsterIcon", true, 32)] {
    let directory = assets.appendingPathComponent("\(name).imageset")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for scale in 1...3 {
        let filename = name + (scale == 1 ? "" : "@\(scale)x") + ".png"
        try render(size: baseSize * scale, template: template).write(to: directory.appendingPathComponent(filename))
        images.append(["idiom": "universal", "scale": "\(scale)x", "filename": filename])
    }
    var catalog: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    if template { catalog["properties"] = ["template-rendering-intent": "template"] }
    let data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("Contents.json"))
}
