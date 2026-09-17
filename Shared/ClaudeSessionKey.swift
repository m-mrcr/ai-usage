import Foundation
import Security

/// Places the claude.ai session key the user pasted in themselves into an AI Usage-only Keychain item.
///
/// Never touches Claude Code's `Claude Code-credentials`. Writing to that item would make macOS
/// swap its partition list to the writer, causing Claude Code to repeatedly prompt for a password —
/// so sharing it is avoided entirely.
///
/// This is an account-wide credential with broader access than a scoped OAuth token.
/// It's not made the default collection route, and is only used as an optional fallback when there are no OAuth credentials.
enum ClaudeSessionKey {
    static let service = "jp.co.forestx.aiusage.claude-session"
    private static let store = WebSessionStore(service: service)

    static func load() -> String? { store.load(validate: isValid) }

    @discardableResult
    static func save(_ raw: String) -> Bool {
        let value = normalized(raw)
        guard isValid(value) else { return false }
        return store.save(value)
    }

    @discardableResult
    static func remove() -> Bool { store.remove() }

    /// The time of the last sign-in. Lets staleness be judged once it expires.
    static func savedAt() -> Date? { store.savedAt() }

    /// Accepts the value whether it's pasted with a `sessionKey=` prefix, surrounding whitespace, or trailing cookies.
    static func normalized(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "sessionKey=") {
            value = String(value[range.upperBound...])
        }
        if let semicolon = value.firstIndex(of: ";") {
            value = String(value[..<semicolon])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only allows characters that can be sent as a cookie value.
    static func isValid(_ value: String) -> Bool {
        guard value.count >= 16, value.utf8.count <= 4_096 else { return false }
        return value.unicodeScalars.allSatisfy {
            (0x21...0x7E).contains($0.value) && $0.value != 0x3B && $0.value != 0x3D
        }
    }
}
