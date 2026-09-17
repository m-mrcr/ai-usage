import Foundation

/// Claude Code's remaining allowance.
///
/// There are two collection routes, tried in order:
///  1. The OAuth usage endpoint (same as `/usage`). Gets the current value even when
///     Claude Code isn't running, so this is the only one that can update periodically.
///  2. `claude.json` written by the statusLine hook. Only fires from the terminal version,
///     but it's a fallback route that uses neither network nor Keychain.
enum ClaudeCollector {
    static func collect(force: Bool = false) async -> AgentUsage {
        var agent: AgentUsage
        switch await ClaudeUsageAPI.shared.fetch(force: force) {
        case let .result(live):
            agent = fromAPI(live)
        case let .unavailable(reason):
            agent = fromStatusLine(apiFailure: reason)
        }
        // If there are no credentials, ClaudeExtraUsageAPI immediately returns nil, so this is safe even when uninstalled.
        if let extra = await ClaudeExtraUsageAPI.fetch(force: force) {
            agent.extraUsage = ExtraUsage(used: extra.used, limit: extra.limit)
        }
        return agent
    }

    // MARK: - 1) OAuth API

    private static func fromAPI(_ result: ClaudeUsageAPI.FetchResult) -> AgentUsage {
        let payload = result.payload
        var windows: [UsageWindow] = []
        if let five = payload.five_hour, let used = five.utilization {
            windows.append(UsageWindow(id: "five_hour", label: "5h", usedPercent: used,
                                       resetsAt: five.resetDate, windowSeconds: 5 * 3_600))
        }
        if let week = payload.seven_day, let used = week.utilization {
            windows.append(UsageWindow(id: "seven_day", label: "7d", usedPercent: used,
                                       resetsAt: week.resetDate, windowSeconds: 7 * 86_400))
        }
        if let opus = payload.seven_day_opus, let used = opus.utilization {
            windows.append(UsageWindow(id: "seven_day_opus", label: "7d Opus", usedPercent: used,
                                       resetsAt: opus.resetDate, windowSeconds: 7 * 86_400))
        }

        guard !windows.isEmpty else { return fromStatusLine(apiFailure: .networkOrServer) }

        return AgentUsage(
            id: "claude-code", name: "Claude Code", plan: PlanLabel.normalize(result.plan),
            windows: windows, observedAt: result.observedAt,
            source: "usage API", status: result.isStale ? .stale : .ok,
            note: result.isStale
                ? failureNote(result.failureReason)
                : nil
        )
    }

    // MARK: - 2) statusLine's output

    private struct StatusLinePayload: Decodable {
        struct Window: Decodable {
            let used_percentage: Double?
            let resets_at: Double?
        }
        let five_hour: Window?
        let seven_day: Window?
        let observed_at: Double?
    }

    private static func fromStatusLine(apiFailure: ClaudeUsageAPI.FailureReason) -> AgentUsage {
        let installed = FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/.claude")

        guard let data = readSmallFile(at: SnapshotStore.claudeURL, maximumBytes: 256 * 1_024),
              let payload = try? JSONDecoder().decode(StatusLinePayload.self, from: data)
        else {
            return AgentUsage(
                id: "claude-code", name: "Claude Code", plan: nil, windows: [],
                observedAt: nil, source: "-",
                status: installed ? .unavailable : .notInstalled,
                note: installed ? failureNote(apiFailure) : nil
            )
        }

        var windows: [UsageWindow] = []
        if let five = payload.five_hour, let used = validPercent(five.used_percentage) {
            windows.append(UsageWindow(id: "five_hour", label: "5h", usedPercent: used,
                                       resetsAt: validEpoch(five.resets_at, maximumPast: 30 * 86_400,
                                                            maximumFuture: 370 * 86_400),
                                       windowSeconds: 5 * 3_600))
        }
        if let week = payload.seven_day, let used = validPercent(week.used_percentage) {
            windows.append(UsageWindow(id: "seven_day", label: "7d", usedPercent: used,
                                       resetsAt: validEpoch(week.resets_at, maximumPast: 30 * 86_400,
                                                            maximumFuture: 370 * 86_400),
                                       windowSeconds: 7 * 86_400))
        }

        let observedAt = validEpoch(payload.observed_at, maximumPast: 10 * 365 * 86_400,
                                    maximumFuture: 5 * 60)
        let isStale = observedAt.map { Date().timeIntervalSince($0) > 6 * 3_600 } ?? true

        // Even if statusLine's backup data remains, keep reporting why the API side is failing.
        // Setting this to nil here would, once the value goes stale, remove "why isn't this updating" from the screen.
        return AgentUsage(
            id: "claude-code", name: "Claude Code", plan: nil,
            windows: windows, observedAt: observedAt,
            source: "statusLine hook",
            status: windows.isEmpty ? .unavailable : (isStale ? .stale : .ok),
            note: (windows.isEmpty || isStale) ? failureNote(apiFailure) : nil
        )
    }

    private static func failureNote(_ reason: ClaudeUsageAPI.FailureReason?) -> String {
        switch reason {
        case nil:
            return "Showing the last successful API response"
        case .credentialUnavailable:
            return "Claude credentials are unavailable; sign in to Claude Code or allow Keychain access"
        case .credentialExpired:
            return "Claude sign-in expired and could not be refreshed; sign in to Claude Code again, then check again"
        case .terminalSignInRequired:
            return "Claude usage needs a terminal Claude Code sign-in; run claude in Terminal, then check again"
        case .refreshDeferredToCLI:
            return "Claude credentials expired; run claude in Terminal to refresh them, then check again"
        case .sessionKeyRejected:
            return "The saved claude.ai session key was rejected; sign in at claude.ai and paste a new one in Settings"
        case .unauthorized:
            return "Claude credentials were rejected; sign in to Claude Code again"
        case .rateLimited:
            return "Claude usage API is rate-limited; try again later"
        case .networkOrServer:
            return "Claude usage API could not be reached"
        }
    }

    private static func validPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private static func validEpoch(
        _ value: Double?,
        maximumPast: TimeInterval,
        maximumFuture: TimeInterval
    ) -> Date? {
        guard let value, value.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: value)
        let distance = date.timeIntervalSinceNow
        guard distance.isFinite,
              distance >= -maximumPast,
              distance <= maximumFuture
        else { return nil }
        return date
    }

    private static func readSmallFile(at url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes >= 0, maximumBytes < Int.max,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        do {
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
