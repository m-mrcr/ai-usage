import Foundation

/// Normalizes inconsistent plan-name spellings.
///
/// What each tool returns can be an internal identifier (e.g. Codex's `prolite`), or
/// already a display-ready name (e.g. Grok's `X Premium+`).
/// Anything not in the lookup table isn't guessed at — it's only tidied into a readable form.
enum PlanLabel {
    private static let known: [String: String] = [
        // OpenAI / Codex
        "free": "Free",
        "plus": "Plus",
        "pro": "Pro",
        "prolite": "Pro",   // An internal identifier; the tier isn't surfaced in the display
        "team": "Team",
        "business": "Business",
        "enterprise": "Enterprise",
        "edu": "Edu",
        // Anthropic / Claude. Can come in as an identifier with a multiplier, but the tier isn't surfaced in the display.
        "max": "Max",
        "max5x": "Max",
        "max20x": "Max",
    ]

    /// A namespace that can be prefixed. Stripped before checking the lookup table.
    private static let prefixes = ["claudeai", "claude", "anthropic", "chatgpt", "openai"]

    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let safeScalars = raw.unicodeScalars.lazy.filter {
            switch $0.properties.generalCategory {
            case .control, .format, .surrogate: return false
            default: return true
            }
        }.prefix(256)
        guard let trimmed = String(String.UnicodeScalarView(Array(safeScalars)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else { return nil }

        var key = trimmed.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        for prefix in prefixes where key.hasPrefix(prefix) && key != prefix {
            key.removeFirst(prefix.count)
            break
        }
        if let mapped = known[key] { return mapped }

        // If it's already a display-ready name (contains spaces or uppercase letters), use it as-is.
        if trimmed.contains(" ") || trimmed.rangeOfCharacter(from: .uppercaseLetters) != nil {
            return String(trimmed.prefix(128))
        }
        // An unknown identifier is split on delimiters and title-cased word by word. max_20x -> Max 20x
        return String(trimmed
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map(\.capitalized)
            .joined(separator: " ")
            .prefix(128))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
