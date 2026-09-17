import AppKit
import CoreGraphics
import CoreText
import Foundation

// Draws the app icon and outputs an .iconset.
// Design: a 240° gauge open at the bottom, using the same green-to-yellow-to-red palette as the in-app bar.

let canvas = 1024.0
let inset = 100.0                    // macOS's rounded-rect icon leaves a margin around the edge
let plate = canvas - inset * 2
let cornerRadius = 185.0

func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let calm = (0.24, 0.78, 0.51)
let moderate = (0.95, 0.76, 0.22)
let critical = (0.94, 0.33, 0.35)

/// Linearly interpolates the 3 colors over 0...1.
func rampColor(_ t: Double) -> CGColor {
    let clamped = min(max(t, 0), 1)
    let (from, to, local): ((Double, Double, Double), (Double, Double, Double), Double) =
        clamped < 0.5
        ? (calm, moderate, clamped / 0.5)
        : (moderate, critical, (clamped - 0.5) / 0.5)
    return srgb(
        from.0 + (to.0 - from.0) * local,
        from.1 + (to.1 - from.1) * local,
        from.2 + (to.2 - from.2) * local
    )
}


/// The font used for the icon's text.
/// Since it's baked into a PNG before bundling, this is only needed on the build machine.
/// It has no effect on the distributed target.
func iconFont(pointSize: CGFloat) -> NSFont {
    let candidates = ["NotoSansJP-Black", "NotoSansJP-Bold", "NotoSans-Black", "NotoSans-Bold"]
    for name in candidates {
        if let font = NSFont(name: name, size: pointSize) { return font }
    }
    FileHandle.standardError.write(Data(
        "warning: Noto Sans not found. Falling back to the system font.\n".utf8))
    let base = NSFont.systemFont(ofSize: pointSize, weight: .heavy)
    return base.fontDescriptor.withDesign(.rounded)
        .flatMap { NSFont(descriptor: $0, size: pointSize) } ?? base
}

/// Places text inside the arc.
///
/// A Japanese font's line height is taller than a Latin one, so centering via ascent/descent
/// drifts upward. Uses the actual glyph shapes' bounding box (ink bounds) as the reference instead.
func drawCentered(_ text: String, in context: CGContext,
                  center: CGPoint, pointSize: CGFloat) {
    let attributed = NSAttributedString(string: text, attributes: [
        .font: iconFont(pointSize: pointSize),
        .foregroundColor: NSColor.white,
        .kern: -pointSize * 0.02,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

    // ink is relative to the drawing origin, so align its center to `center`
    context.textPosition = CGPoint(x: center.x - ink.midX,
                                   y: center.y - ink.midY)
    CTLineDraw(line, context)
}

func makeImage(size: Double) -> CGImage {
    let scale = size / canvas
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // --- Base plate ---
    let plateRect = CGRect(x: inset, y: inset, width: plate, height: plate)
    let platePath = CGPath(roundedRect: plateRect,
                           cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                           transform: nil)
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let backdrop = CGGradient(
        colorsSpace: space,
        colors: [srgb(0.16, 0.17, 0.21), srgb(0.05, 0.05, 0.07)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        backdrop,
        start: CGPoint(x: 0, y: canvas), end: CGPoint(x: 0, y: 0),
        options: []
    )
    context.restoreGState()

    // Adds a subtle highlight along the top edge to give it a plate-like feel
    context.saveGState()
    context.addPath(platePath)
    context.setLineWidth(3)
    context.setStrokeColor(srgb(1, 1, 1, 0.10))
    context.strokePath()
    context.restoreGState()

    // --- Gauge ---
    let center = CGPoint(x: canvas / 2, y: canvas / 2 - 40)
    let radius = 268.0
    let lineWidth = 104.0
    let startAngle = 210.0 * .pi / 180      // bottom left
    let sweep = 240.0 * .pi / 180           // through the top, to the bottom right
    let filled = 0.66                        // where the fill color transitions

    context.setLineCap(.round)
    context.setLineWidth(lineWidth)

    // Track
    context.setStrokeColor(srgb(1, 1, 1, 0.11))
    context.addArc(center: center, radius: radius,
                   startAngle: startAngle, endAngle: startAngle - sweep,
                   clockwise: true)
    context.strokePath()

    // Fill. The gradient along the arc is rendered as a series of fine segments.
    let steps = 160
    let fillSweep = sweep * filled
    for step in 0..<steps {
        let t0 = Double(step) / Double(steps)
        let t1 = Double(step + 1) / Double(steps)
        // Overlap segments slightly to hide the seams
        let a0 = startAngle - fillSweep * t0
        let a1 = startAngle - fillSweep * min(t1 + 0.35 / Double(steps), 1)
        context.setStrokeColor(rampColor(t0 * filled / 0.9))
        context.setLineCap(step == 0 || step == steps - 1 ? .round : .butt)
        context.addArc(center: center, radius: radius,
                       startAngle: a0, endAngle: a1, clockwise: true)
        context.strokePath()
    }

    // --- Text ---
    drawCentered("AI", in: context, center: CGPoint(x: center.x, y: center.y - 6),
                 pointSize: 214)

    return context.makeImage()!
}

// --- Export ---
let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir,
                                         withIntermediateDirectories: true)

let variants: [(name: String, size: Double)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let image = makeImage(size: variant.size)
    let url = URL(fileURLWithPath: "\(outputDir)/\(variant.name).png")
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: variant.size, height: variant.size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try! data.write(to: url)
    print("  \(variant.name).png  (\(Int(variant.size))px)")
}
