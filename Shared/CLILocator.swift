import Foundation

/// Locates a command's actual executable without relying on PATH.
///
/// An app launched from Finder doesn't inherit the PATH set up by shell init files.
/// Looks directly in commonly used install locations instead.
enum CLILocator {
    /// A cap so scanning doesn't grow without bound for version managers that keep a bin per version.
    private static let versionLimit = 64

    static func searchPaths() -> [URL] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser

        var paths = [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
        ].map(URL.init(fileURLWithPath:)) + [
            ".local/bin", ".claude/local", ".volta/bin", ".asdf/shims",
            ".bun/bin", ".npm-global/bin", ".npm-packages/bin", "n/bin",
            "Library/pnpm",
        ].map(home.appendingPathComponent)

        // nvm/fnm keep a bin per Node version, so expand just one level.
        for (root, suffix) in [
            (home.appendingPathComponent(".nvm/versions/node"), "bin"),
            (home.appendingPathComponent(".fnm/node-versions"), "installation/bin"),
            (home.appendingPathComponent("Library/Application Support/fnm/node-versions"),
             "installation/bin"),
        ] {
            guard let entries = try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            paths += entries.prefix(versionLimit).map { $0.appendingPathComponent(suffix) }
        }
        return paths
    }

    static func locate(_ name: String) -> URL? {
        let manager = FileManager.default
        for directory in searchPaths() {
            let candidate = directory.appendingPathComponent(name)
            if manager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
