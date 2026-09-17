import Foundation

/// Tools that are installed but don't expose their remaining allowance locally.
/// Listing them would just occupy space with an empty window, so they're only mentioned in a Settings note.
enum UnsupportedAgents {
    private static let known: [(name: String, marker: String)] = [
        ("Gemini CLI", ".gemini"),
    ]

    static var detected: [String] {
        known
            .filter { FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/\($0.marker)") }
            .map(\.name)
    }
}
