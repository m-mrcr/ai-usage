import Foundation

/// Codex's remaining allowance.
///
/// Codex automatically writes `rate_limits` into its session log
/// (~/.codex/sessions/**/rollout-*.jsonl). No hook install or API call is needed — just read the latest one.
enum CodexCollector {
    private static let sessionsRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    /// Only looks at the tail of each file. rate_limits is written often, so this is enough.
    private static let tailBytes = 2 * 1_024 * 1_024

    static func collect(force: Bool = false) -> AgentUsage {
        // If the official client can be asked directly, that's always the freshest. The log only grows with actual use.
        let live = CodexAppServer.snapshot(force: force)
        let hasLogs = FileManager.default.fileExists(atPath: sessionsRoot.path)
        guard live != nil || hasLogs || CodexAppServer.isAvailable else {
            return AgentUsage(id: "codex", name: "Codex", plan: nil, windows: [],
                              observedAt: nil, source: logSource,
                              status: .notInstalled, note: nil)
        }

        let source = live == nil ? logSource : liveSource
        let observations = live?.observations ?? latestObservations()
        guard let hit = selectBucket(from: observations) else {
            return AgentUsage(
                id: "codex", name: "Codex",
                plan: observations.first.flatMap { PlanLabel.normalize($0.limits.plan_type) },
                windows: [], observedAt: nil, source: source,
                status: .unavailable,
                note: hasOnlyModelBuckets(observations)
                    ? "Only model-specific Codex limits were found; run Codex on your plan's default model, then check again"
                    : "Run Codex once to populate its session log"
            )
        }

        var windows = usableWindows(of: hit.limits)
        // Per-model windows are shown in the list too, but never used as the representative value (supplementary).
        for other in observations where !other.isPlanBucket {
            windows.append(contentsOf: usableWindows(of: other.limits, supplementary: true))
        }
        let isStale = Date().timeIntervalSince(hit.observedAt) > 6 * 3_600

        return AgentUsage(
            id: "codex",
            name: "Codex",
            plan: PlanLabel.normalize(hit.limits.plan_type),
            windows: windows,
            observedAt: hit.observedAt,
            source: source,
            status: windows.isEmpty ? .unavailable : (isStale ? .stale : .ok),
            note: nil,
            // A value only known via the live route. Stays nil on the log-only fallback (no row is shown).
            resetCredits: live?.resetCreditsAvailable.map(ResetCredits.init(available:))
        )
    }

    /// The source. Guidance differs depending on which one was readable, so this is kept for display too.
    static let liveSource = "Codex CLI"
    static let logSource = "session log"

    // MARK: - JSON shape

    struct RateLimits: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let window_minutes: Int?
            let resets_at: Double?
        }
        let primary: Window?
        let secondary: Window?
        let plan_type: String?
        /// Codex writes the plan window and per-model windows as separate records in the same log.
        /// e.g. the plan window is "codex", GPT-5.3-Codex-Spark is "codex_bengalfox".
        let limit_id: String?
        let limit_name: String?
    }

    /// The latest observation for one bucket.
    struct Observation {
        let limits: RateLimits
        let observedAt: Date

        var bucketKey: String { limits.limit_id ?? "" }
        /// The plan-wide window. Confusing it with a per-model window would show 0% for an unused model.
        var isPlanBucket: Bool {
            guard let id = limits.limit_id else { return true }
            return id == planLimitID
        }
    }

    static let planLimitID = "codex"

    private static func window(from raw: RateLimits.Window, fallbackID: String) -> UsageWindow? {
        guard let used = raw.used_percent,
              used.isFinite,
              (0...100).contains(used)
        else { return nil }

        let minutes = raw.window_minutes ?? 0
        guard minutes >= 0, minutes <= 10 * 365 * 24 * 60 else { return nil }
        let label: String
        switch minutes {
        case 0: label = fallbackID == "primary" ? "Usage" : "Secondary"
        case ..<60: label = "\(minutes)m"
        case ..<1_440: label = "\(minutes / 60)h"
        case 10_080: label = "7d"
        case 43_200: label = "30d"
        default: label = "\(minutes / 1_440)d"
        }
        return UsageWindow(
            id: minutes > 0 ? "\(fallbackID)-w\(minutes)" : fallbackID,
            label: label,
            usedPercent: used,
            resetsAt: validEpoch(raw.resets_at),
            windowSeconds: minutes > 0 ? TimeInterval(minutes) * 60 : nil
        )
    }

    static func usableWindows(
        of limits: RateLimits, supplementary: Bool = false
    ) -> [UsageWindow] {
        let prefix = supplementary ? (limits.limit_id ?? "model") + "-" : ""
        let name = supplementary ? shortBucketName(of: limits) : nil
        var windows: [UsageWindow] = []
        for (raw, fallbackID) in [(limits.primary, "primary"), (limits.secondary, "secondary")] {
            guard let raw, var window = window(from: raw, fallbackID: fallbackID) else { continue }
            if supplementary {
                window.id = prefix + window.id
                window.isSupplementary = true
                if let name { window.label = "\(name) \(window.label)" }
            }
            windows.append(window)
        }
        return windows
    }

    /// A display name like "GPT-5.3-Codex-Spark" is too long, so only the last segment is used.
    /// On a version with no name, an internal id like `codex_bengalfox` is used with the prefix dropped.
    static func shortBucketName(of limits: RateLimits) -> String? {
        if let name = limits.limit_name, !name.isEmpty {
            return name.split(separator: "-").last.map(String.init) ?? name
        }
        guard let id = limits.limit_id, !id.isEmpty else { return nil }
        return id.hasPrefix(planLimitID + "_")
            ? String(id.dropFirst(planLimitID.count + 1))
            : id
    }

    /// Decides which bucket to show. Takes only the plan window, never a per-model one.
    ///
    /// Taking "whichever was written last" would flip between the plan window and a per-model
    /// window depending on which model was used most recently. An unused per-model window stays
    /// at 0%, so showing it instead would misleadingly suggest plenty of room. When there's no
    /// plan window, no number is shown and that fact is reported instead.
    /// An old-format Codex with no `limit_id` is also treated as a plan window.
    static func selectBucket(from observations: [Observation]) -> Observation? {
        observations
            .filter { $0.isPlanBucket && !usableWindows(of: $0.limits).isEmpty }
            .max { $0.observedAt < $1.observedAt }
    }

    /// A state with no plan window but only per-model windows. "Run Codex once" would be the wrong advice here.
    static func hasOnlyModelBuckets(_ observations: [Observation]) -> Bool {
        !observations.isEmpty && observations.allSatisfy { !$0.isPlanBucket }
    }

    // MARK: - Log scanning

    /// Collects the single latest observation per bucket.
    private static func latestObservations() -> [Observation] {
        var latest: [String: Observation] = [:]
        for file in recentSessionFiles() {
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
            for hit in scanTail(of: file) {
                guard let observedAt = hit.observedAt
                        ?? modified.flatMap(plausibleObservationDate)
                else { continue }
                let observation = Observation(limits: hit.limits, observedAt: observedAt)
                let key = observation.bucketKey
                if let existing = latest[key], existing.observedAt >= observedAt { continue }
                latest[key] = observation
            }
        }
        return Array(latest.values)
    }

    /// Up to 20, most recently modified first.
    private static func recentSessionFiles() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: sessionsRoot, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [(URL, Date)] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            found.append((url, values.contentModificationDate ?? .distantPast))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(20).map(\.0)
    }

    /// Reads a file's tail backward and extracts the latest rate_limits for each `limit_id`.
    /// Returning only the very last entry would get dragged toward whichever model's bucket was used most recently.
    static func scanTail(of url: URL) -> [(limits: RateLimits, observedAt: Date?)] {
        guard let data = readTail(of: url, maximumBytes: tailBytes) else { return [] }

        var seen = Set<String>()
        var hits: [(limits: RateLimits, observedAt: Date?)] = []
        for rawLine in data.split(separator: 0x0A).reversed() {
            guard let line = String(data: Data(rawLine), encoding: .utf8) else { continue }
            guard line.contains("\"rate_limits\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  root["type"] as? String == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = findRateLimits(in: payload)
            else { continue }

            // A line whose timestamp can't be read is discarded and scanning continues further back, so mark it as seen only once it's actually accepted.
            guard !seen.contains(limits.limit_id ?? "") else { continue }

            var observedAt: Date?
            if let rawTimestamp = root["timestamp"] {
                guard let timestamp = rawTimestamp as? String,
                      let parsed = parseTimestamp(timestamp)
                else { continue }
                observedAt = parsed
            }
            seen.insert(limits.limit_id ?? "")
            hits.append((limits, observedAt))
        }
        return hits
    }

    /// Even if the offset lands mid-UTF-8, discards the leading incomplete line and parses the rest line by line.
    private static func readTail(of url: URL, maximumBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let count = min(UInt64(maximumBytes), size)
        let offset = size - count
        do {
            try handle.seek(toOffset: offset)
            guard var data = try handle.read(upToCount: Int(count)) else { return nil }
            if offset > 0 {
                guard let newline = data.firstIndex(of: 0x0A) else { return nil }
                let start = data.index(after: newline)
                data = start < data.endIndex ? Data(data[start...]) : Data()
            }
            return data
        } catch {
            return nil
        }
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text))
            .flatMap(plausibleObservationDate)
    }

    private static func plausibleObservationDate(_ date: Date) -> Date? {
        let distance = date.timeIntervalSinceNow
        guard distance.isFinite,
              distance >= -10 * 365 * 86_400,
              distance <= 5 * 60
        else { return nil }
        return date
    }

    private static func validEpoch(_ value: Double?) -> Date? {
        guard let value, value.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: value)
        let distance = date.timeIntervalSinceNow
        guard distance.isFinite,
              distance >= -370 * 86_400,
              distance <= 10 * 365 * 86_400
        else { return nil }
        return date
    }

    /// The nesting depth of rate_limits varies by event type, so this searches recursively.
    static func findRateLimits(in object: Any) -> RateLimits? {
        var remainingNodes = 2_048
        return findRateLimits(in: object, depth: 0, remainingNodes: &remainingNodes)
    }

    private static func findRateLimits(
        in object: Any,
        depth: Int,
        remainingNodes: inout Int
    ) -> RateLimits? {
        guard depth <= 32, remainingNodes > 0 else { return nil }
        remainingNodes -= 1

        guard let dict = object as? [String: Any] else {
            guard let array = object as? [Any] else { return nil }
            for value in array {
                if let limits = findRateLimits(
                    in: value, depth: depth + 1, remainingNodes: &remainingNodes
                ) { return limits }
            }
            return nil
        }
        if let raw = dict["rate_limits"] as? [String: Any],
           JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let limits = try? JSONDecoder().decode(RateLimits.self, from: data),
           hasUsableWindow(in: limits) {
            return limits
        }
        for value in dict.values {
            if let limits = findRateLimits(
                in: value, depth: depth + 1, remainingNodes: &remainingNodes
            ) { return limits }
        }
        return nil
    }

    private static func hasUsableWindow(in limits: RateLimits) -> Bool {
        if let primary = limits.primary,
           window(from: primary, fallbackID: "primary") != nil {
            return true
        }
        if let secondary = limits.secondary,
           window(from: secondary, fallbackID: "secondary") != nil {
            return true
        }
        return false
    }
}
