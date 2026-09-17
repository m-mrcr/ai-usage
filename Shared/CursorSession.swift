import Foundation

/// The cursor.com session. Both Grok Bot and Cursor run on this account, so
/// one sign-in covers both.
///
/// Usage never lands locally at all, and the token each app holds is encrypted with safeStorage.
/// To avoid opening another app's encrypted store, the user is instead asked to sign in inside this
/// app, and only that cookie is held onto.
enum CursorSession {
    /// Kept as its original name. Changing it would make the saved sign-in unreadable.
    static let service = "jp.co.forestx.aiusage.grokbot-session"
    private static let store = WebSessionStore(service: service)

    /// What's sent is the Cookie header itself. Which cookies are needed is up to the other side,
    /// so instead of hardcoding names, everything from sign-in is held onto together.
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

    static func normalized(_ raw: String) -> String {
        raw.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains("=") }
            .joined(separator: "; ")
    }

    /// Only allows characters that can be sent as a Cookie header. Letting a newline through would split the header.
    static func isValid(_ value: String) -> Bool {
        guard value.count >= 8, value.utf8.count <= 8_192, value.contains("=") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (0x20...0x7E).contains(scalar.value)
        }
    }
}
