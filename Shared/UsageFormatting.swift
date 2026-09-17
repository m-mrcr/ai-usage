import AppKit
import SwiftUI

extension UsageWindow {
    var severity: UsageSeverity { UsageSeverity.of(usedPercent) }
    var tint: Color { severity.color }

    /// API values use the 0...100 scale, while Foundation's percent style expects 0...1.
    /// FormatStyle follows the user's locale (including percent-sign placement and digits).
    private var usedFraction: Double { min(max(usedPercent, 0), 100) / 100 }
    private var remainingFraction: Double { min(max(remainingPercent, 0), 100) / 100 }

    var usedText: String {
        usedFraction.formatted(.percent.precision(.fractionLength(0)))
    }

    var remainingValueText: String {
        remainingFraction.formatted(.percent.precision(.fractionLength(0)))
    }

    var remainingText: String { "\(remainingValueText) left" }
}

extension AgentUsage {
    /// The agent's identity color. Since the bar's color represents severity, identity is conveyed via the dot instead.
    ///
    /// Matched to each company's actual brand. Prioritizes intuitive association, and never
    /// assigns a color that doesn't exist for a brand just to aid distinguishability.
    var accent: Color {
        switch id {
        case "claude-code": return Color(red: 0.85, green: 0.47, blue: 0.28)
        case "codex": return Color(red: 139 / 255, green: 124 / 255, blue: 246 / 255)
        // Grok and Grok Bot are the same xAI brand, both monochrome. Treated with the same color.
        case "grok", "grok-bot": return grokAccent
        case "gemini": return Color(red: 0.36, green: 0.62, blue: 0.98)
        case "cursor": return cursorAccent
        default: return .gray
        }
    }

    /// Grok is a monochrome-family cool gray. Darker in light appearance, lighter in dark appearance, to preserve distinguishability.
    private var grokAccent: Color {
        Self.adaptive(
            name: "AIUsage.GrokAccent",
            light: (86, 99, 114),
            dark: (170, 181, 194)
        )
    }

    /// Cursor is fully achromatic. The official icon is made up of only black and white.
    /// Made darker than Grok's cool gray (light appearance) and lighter (dark appearance),
    /// so the two monochrome accents aren't mistaken for each other.
    private var cursorAccent: Color {
        Self.adaptive(
            name: "AIUsage.CursorAccent",
            light: (26, 26, 26),
            dark: (240, 240, 240)
        )
    }

    /// Swaps the color based on appearance, so it stays legible in both light and dark.
    private static func adaptive(
        name: String,
        light: (Int, Int, Int),
        dark: (Int, Int, Int)
    ) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat(r) / 255,
                green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255,
                alpha: 1
            )
        })
    }
}

extension AgentStatus {
    var isActionable: Bool { self == .ok || self == .stale }
}

extension ResetCredits {
    func summaryText(language: AppLanguage) -> String {
        switch available {
        case 0: return L10n.text("widget.resetCredits.none", language: language)
        case 1: return L10n.text("widget.resetCredits.one", language: language)
        default: return L10n.format("widget.resetCredits.other.format", language: language, available)
        }
    }
}

extension ExtraUsage {
    /// The currency is fixed to Anthropic's billing unit (USD); only digit grouping follows the language setting.
    func summaryText(language: AppLanguage) -> String {
        L10n.format(
            "widget.extraUsage.format", language: language,
            Self.currencyText(used, language: language),
            Self.currencyText(limit, language: language)
        )
    }

    private static func currencyText(_ value: Double, language: AppLanguage) -> String {
        value.formatted(
            .currency(code: "USD").precision(.fractionLength(2)).locale(language.locale)
        )
    }
}

extension AgentUsage {
    /// The widget's "EXTRAS" row. Reset credits for Codex, pay-as-you-go usage for Claude.
    /// Only Claude also explicitly states "not fetched". This is a fixed slot meant to make
    /// Codex/Claude comparable at a glance, so it avoids looking asymmetric with only one side's value disappearing.
    func extrasText(language: AppLanguage) -> String? {
        if let resetCredits { return resetCredits.summaryText(language: language) }
        if let extraUsage { return extraUsage.summaryText(language: language) }
        if id == "claude-code" { return L10n.text("widget.extraUsage.off", language: language) }
        return nil
    }
}
