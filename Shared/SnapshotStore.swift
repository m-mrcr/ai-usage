import Foundation

/// The handoff point between the main app and the widget extension.
///
/// The App Group publishes only values cleared for display; the full cache is kept separate,
/// in an Application Support directory private to the main app.
enum SnapshotStore {
    static let appGroupID = "Y45S2Q5K9V.com.martinmercer.aiusage"
    private static let maximumSnapshotBytes = 1_048_576

    enum StoreError: LocalizedError {
        case appGroupUnavailable
        case snapshotTooLarge(Int)
        case invalidSnapshot(String)

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "The App Group container is unavailable"
            case .snapshotTooLarge(let bytes):
                return "The usage snapshot is unexpectedly large (\(bytes) bytes)"
            case .invalidSnapshot(let reason):
                return "The usage snapshot is invalid: \(reason)"
            }
        }
    }

    private static func publishedDirectory() throws -> URL {
        let manager = FileManager.default
        guard let group = manager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { throw StoreError.appGroupUnavailable }
        try manager.createDirectory(at: group, withIntermediateDirectories: true)
        return group
    }

    private static func privateDirectory() throws -> URL {
        let manager = FileManager.default
        let directory = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsage", isDirectory: true)
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    /// The published snapshot that Widget/AppIntent reference. nil if the App Group is unreachable.
    static var snapshotURL: URL? {
        try? publishedDirectory().appendingPathComponent("snapshot.json")
    }

    /// Main-app-only data written by Claude Code's statusLine shim.
    static var claudeURL: URL {
        let directory = (try? privateDirectory()) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsage", isDirectory: true)
        return directory.appendingPathComponent("claude.json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// A compatibility API for the widget. Failures show as empty, and an expired value is
    /// excluded from the published snapshot even while the main app isn't running.
    static func load() -> UsageSnapshot {
        ((try? loadPublished()) ?? .empty).expiringStaleData()
    }

    static func loadPublished() throws -> UsageSnapshot {
        try load(from: publishedDirectory().appendingPathComponent("snapshot.json"))
    }

    static func loadPrivate() throws -> UsageSnapshot {
        try load(from: privateDirectory().appendingPathComponent("snapshot-private.json"))
    }

    private static func load(from url: URL) throws -> UsageSnapshot {
        let resource = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = resource.fileSize ?? 0
        guard size <= maximumSnapshotBytes else { throw StoreError.snapshotTooLarge(size) }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let snapshot = try makeDecoder().decode(UsageSnapshot.self, from: data)
        try validate(snapshot)
        return snapshot
    }

    static func savePublished(_ snapshot: UsageSnapshot) throws {
        try save(snapshot, to: publishedDirectory().appendingPathComponent("snapshot.json"))
    }

    static func savePrivate(_ snapshot: UsageSnapshot) throws {
        try save(snapshot, to: privateDirectory().appendingPathComponent("snapshot-private.json"))
    }

    private static func save(_ snapshot: UsageSnapshot, to url: URL) throws {
        try validate(snapshot)
        let data = try makeEncoder().encode(snapshot)
        guard data.count <= maximumSnapshotBytes else {
            throw StoreError.snapshotTooLarge(data.count)
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    static func removePublished() throws {
        let url = try publishedDirectory().appendingPathComponent("snapshot.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func validate(_ snapshot: UsageSnapshot) throws {
        let now = Date()
        guard snapshot.agents.count <= 32 else {
            throw StoreError.invalidSnapshot("too many agents")
        }
        let isEmptySentinel = snapshot.agents.isEmpty && snapshot.updatedAt == .distantPast
        guard isEmptySentinel || plausibleObservationDate(snapshot.updatedAt, now: now) else {
            throw StoreError.invalidSnapshot("invalid update date")
        }

        let agentIDs = snapshot.agents.map(\.id)
        guard Set(agentIDs).count == agentIDs.count else {
            throw StoreError.invalidSnapshot("duplicate agent identifiers")
        }
        if let preferred = snapshot.preferredAgentID {
            guard preferred.count <= 128, agentIDs.contains(preferred), safeText(preferred) else {
                throw StoreError.invalidSnapshot("invalid preferred agent")
            }
        }

        for agent in snapshot.agents {
            guard agent.id.count <= 128, agent.name.count <= 256,
                  agent.windows.count <= 16,
                  agent.plan?.count ?? 0 <= 128,
                  agent.source.count <= 256,
                  agent.note?.count ?? 0 <= 1_024,
                  safeText(agent.id), safeText(agent.name), safeText(agent.source),
                  agent.plan.map(safeText) ?? true,
                  agent.note.map(safeText) ?? true
            else { throw StoreError.invalidSnapshot("oversized agent fields") }
            if let resetCredits = agent.resetCredits {
                guard (0...9_999).contains(resetCredits.available) else {
                    throw StoreError.invalidSnapshot("invalid reset credits")
                }
            }
            if let extraUsage = agent.extraUsage {
                guard extraUsage.used.isFinite, extraUsage.limit.isFinite,
                      (0...1_000_000).contains(extraUsage.used),
                      (0...1_000_000).contains(extraUsage.limit)
                else { throw StoreError.invalidSnapshot("invalid extra usage") }
            }
            if let observedAt = agent.observedAt,
               !plausibleObservationDate(observedAt, now: now) {
                throw StoreError.invalidSnapshot("invalid observation date")
            }

            let windowIDs = agent.windows.map(\.id)
            guard Set(windowIDs).count == windowIDs.count else {
                throw StoreError.invalidSnapshot("duplicate usage window identifiers")
            }
            for window in agent.windows {
                guard window.usedPercent.isFinite,
                      (0...100).contains(window.usedPercent),
                      window.id.count <= 128, window.label.count <= 128,
                      safeText(window.id), safeText(window.label)
                else { throw StoreError.invalidSnapshot("invalid usage window") }
            }
        }
    }

    private static func plausibleObservationDate(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age.isFinite && age >= -5 * 60 && age <= 10 * 365 * 86_400
    }

    private static func safeText(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate: return false
            default: return true
            }
        }
    }
}
