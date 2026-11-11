import SwiftUI

/// A gauge for the menu bar. Fills the same 240° arc as the app icon, by the usage percentage.
/// MenuBarExtra's label can't reliably render a complex view, so this is baked into an image first.
enum MenuBarGauge {
    static let side: CGFloat = 17

    @MainActor
    static func image(percent: Double) -> NSImage? {
        let renderer = ImageRenderer(
            content: GaugeGlyph(percent: percent).frame(width: side, height: side)
        )
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        // Deliberately not marked as a template image — that would flatten it to one color and lose the severity color.
        let image = NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
        image.isTemplate = false
        return image
    }
}

struct GaugeGlyph: View {
    /// Percent used. Drawn as remaining allowance (gas-tank style): the arc shrinks as usage
    /// climbs, while its color still tracks `percent` so it still gets more alarming near empty.
    let percent: Double

    private var remainingFraction: Double { 1 - min(max(percent, 0), 100) / 100 }

    var body: some View {
        ZStack {
            GaugeArc(fraction: 1)
                .stroke(Color.primary.opacity(0.28),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
            GaugeArc(fraction: remainingFraction)
                .stroke(UsageSeverity.of(percent).color,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }
}

/// A 240° arc open at the bottom. SwiftUI's y-axis points down, so increasing angle appears clockwise.
struct GaugeArc: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY + 1)
        let radius = min(rect.width, rect.height) / 2 - 2.2
        let start = Angle(degrees: 150)                     // from the bottom left
        let end = start + Angle(degrees: 240 * fraction)    // through the top, to the bottom right
        path.addArc(center: center, radius: radius,
                    startAngle: start, endAngle: end, clockwise: false)
        return path
    }
}
