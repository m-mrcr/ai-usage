import SwiftUI

/// The usage bar.
///
/// ProgressView's determinate fill isn't rendered by the widget's renderer — only the track
/// gets drawn — so this is custom-drawn with shapes instead.
struct UsageBar: View {
    let percent: Double
    var height: CGFloat = 7
    let language: AppLanguage

    private var fraction: Double { min(max(percent, 0), 100) / 100 }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))

                if fraction > 0 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: UsageSeverity.of(percent).gradient,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        // Sets a floor, since an extremely thin bar would crush the rounded corners
                        .frame(width: max(height, geometry.size.width * fraction))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("common.usedQuota", language: language))
        .accessibilityValue(
            (min(max(percent, 0), 100) / 100)
                .formatted(
                    .percent
                        .precision(.fractionLength(0))
                        .locale(language.locale)
                )
        )
    }
}

/// Usage severity tiers. Colors are centralized here.
enum UsageSeverity {
    case calm, moderate, high, critical

    static func of(_ percent: Double) -> UsageSeverity {
        switch percent {
        case ..<50: return .calm
        case ..<75: return .moderate
        case ..<90: return .high
        default: return .critical
        }
    }

    var color: Color {
        switch self {
        case .calm: return Color(red: 0.24, green: 0.78, blue: 0.51)
        case .moderate: return Color(red: 0.95, green: 0.76, blue: 0.22)
        case .high: return Color(red: 0.97, green: 0.55, blue: 0.20)
        case .critical: return Color(red: 0.94, green: 0.33, blue: 0.35)
        }
    }

    /// Starts slightly darker at the left edge to add depth.
    var gradient: [Color] {
        [color.opacity(0.72), color]
    }
}

/// The window-length label. A short window like 5h is given color to stand out.
struct WindowChip: View {
    let window: UsageWindow
    var emphasized: Bool = false
    let language: AppLanguage

    var body: some View {
        Text(L10n.windowLabel(window, language: language))
            .font(.system(size: 9, weight: .bold))
            // Severity remains visible in the background/outline; primary text keeps
            // compact labels readable in light mode and Increase Contrast.
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                (emphasized ? window.tint.opacity(0.16) : Color.primary.opacity(0.07)),
                in: Capsule()
            )
            .overlay {
                if emphasized {
                    Capsule().stroke(window.tint.opacity(0.65), lineWidth: 0.5)
                }
            }
            .frame(minWidth: 26, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(
                L10n.format(
                    "common.quotaWindow.format",
                    language: language,
                    L10n.windowLabel(window, language: language)
                )
            )
    }
}
