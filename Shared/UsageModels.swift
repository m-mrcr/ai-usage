import Foundation

/// A single limit window (e.g. Claude's 5-hour/weekly window, Codex's weekly window).
struct UsageWindow: Codable, Hashable, Identifiable {
    var id: String            // "five_hour" / "seven_day" / "primary" ...
    var label: String         // A short label for on-screen display
    var usedPercent: Double   // 0...100
    var resetsAt: Date?
    /// The window's length in seconds. Used to judge whether it's a 5-hour window and to compute the consumption pace.
    var windowSeconds: TimeInterval?
    /// A supplementary window that isn't the plan-wide one (e.g. Codex's per-model limit).
    /// Stays at 0% if unused, so if the headline or summary picked it up it would misleadingly suggest plenty of room.
    /// Shown in the list, but excluded from selection as the representative value.
    var isSupplementary: Bool

    init(id: String, label: String, usedPercent: Double, resetsAt: Date?,
         windowSeconds: TimeInterval?, isSupplementary: Bool = false) {
        self.id = id
        self.label = label
        self.usedPercent = Self.validPercent(usedPercent)
        self.resetsAt = Self.validDate(resetsAt)
        self.windowSeconds = Self.validWindowSeconds(windowSeconds)
        self.isSupplementary = isSupplementary
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, usedPercent, resetsAt, windowSeconds, isSupplementary
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)

        let rawPercent = try values.decode(Double.self, forKey: .usedPercent)
        guard rawPercent.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .usedPercent, in: values, debugDescription: "Usage percent must be finite"
            )
        }
        usedPercent = Self.validPercent(rawPercent)

        resetsAt = Self.validDate(try values.decodeIfPresent(Date.self, forKey: .resetsAt))
        windowSeconds = Self.validWindowSeconds(
            try values.decodeIfPresent(TimeInterval.self, forKey: .windowSeconds)
        )
        // An old snapshot doesn't have this field. Defaults to being treated as a plan window.
        isSupplementary = try values.decodeIfPresent(Bool.self, forKey: .isSupplementary) ?? false
    }

    private static func validPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }

    private static func validDate(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite,
              timestamp >= 946_684_800,
              timestamp <= 7_258_118_400
        else { return nil }
        return date
    }

    private static func validWindowSeconds(_ seconds: TimeInterval?) -> TimeInterval? {
        guard let seconds, seconds.isFinite, seconds > 0,
              seconds <= 10 * 365 * 86_400
        else { return nil }
        return seconds
    }

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    /// The shorter the window, the more it's a limit that "kicks in right now". A check for prioritizing the 5-hour window's display.
    var isShortWindow: Bool {
        guard let windowSeconds else { return false }
        return windowSeconds <= 6 * 3_600
    }

    /// Renders from now until `date` as e.g. "2d 3h" / "42m".
    static func durationText(until date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval.isFinite else { return "unknown" }
        guard interval <= 10 * 365 * 86_400 else { return "unknown" }
        if interval <= -60 { return "passed" }
        if interval < 60 { return "<1m" }
        let seconds = Int(interval.rounded(.down))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// The time remaining until reset.
    var resetsInText: String? {
        resetsAt.map { UsageWindow.durationText(until: $0) }
    }
}

/// Codex's manual/reset credits. Extra uses available after the plan window is exhausted.
/// `available` is only known from a live app-server response, so it's nil on a log-only fallback.
struct ResetCredits: Codable, Hashable {
    var available: Int
}

/// Claude's pay-as-you-go usage (extra usage beyond the plan window). Denominated in USD, matching the provider's display.
struct ExtraUsage: Codable, Hashable {
    var used: Double
    var limit: Double
}

enum AgentStatus: String, Codable {
    case ok            // has a fresh real measurement
    case stale         // has a value, but it's old
    case unavailable   // installed, but data hasn't been fetched
    case notInstalled  // not installed at all
}

struct AgentUsage: Codable, Hashable, Identifiable {
    static let maximumStaleRetention: TimeInterval = 30 * 86_400
    var id: String            // "claude-code" / "codex" ...
    var name: String
    var plan: String?
    var windows: [UsageWindow]
    var observedAt: Date?
    var source: String        // Where the data comes from (for the UI tooltip)
    var status: AgentStatus
    var note: String?         // Guidance on what to do when data hasn't been fetched
    /// Codex only. nil if there's no live app-server route (not included in a log-only fallback).
    var resetCredits: ResetCredits? = nil
    /// Claude only. nil if unavailable or unset (the display side falls back to "Extra usage off").
    var extraUsage: ExtraUsage? = nil

    /// The candidate for the representative value. Looks only at plan windows, except when there are only supplementary ones.
    var primaryWindows: [UsageWindow] {
        let planned = windows.filter { !$0.isSupplementary }
        return planned.isEmpty ? windows : planned
    }

    /// The most constrained window. Used for the menu bar summary.
    var tightestWindow: UsageWindow? {
        primaryWindows.max { $0.usedPercent < $1.usedPercent }
    }

    /// The window representing this agent. Prioritizes a short window like the 5-hour one.
    var headlineWindow: UsageWindow? {
        let short = primaryWindows.filter(\.isShortWindow)
        if let pick = short.max(by: { $0.usedPercent < $1.usedPercent }) { return pick }
        return tightestWindow
    }

    /// The display order. Plan windows come first, and within those, shorter windows come first.
    var displayWindows: [UsageWindow] {
        windows.sorted { lhs, rhs in
            if lhs.isSupplementary != rhs.isSupplementary { return !lhs.isSupplementary }
            return (lhs.windowSeconds ?? .greatestFiniteMagnitude)
                < (rhs.windowSeconds ?? .greatestFiniteMagnitude)
        }
    }

    /// A display freshness that combines the collector's status with the observation time.
    var displayStatus: AgentStatus {
        displayStatus(at: Date())
    }

    func displayStatus(at now: Date) -> AgentStatus {
        guard !windows.isEmpty else { return status }
        guard status == .ok else { return status }
        guard let observedAt else { return .stale }
        let age = now.timeIntervalSince(observedAt)
        guard age.isFinite else { return .stale }
        guard age >= -5 * 60 else { return .stale }
        return age > 6 * 3_600 ? .stale : .ok
    }

    /// A stale percentage stops being meaningful once its quota window has reset.
    /// Unknown reset dates get a bounded fallback so an abandoned local log cannot
    /// remain on screen forever.
    func expiringStaleData(at now: Date) -> AgentUsage {
        let observationIsStale = displayStatus(at: now) == .stale
        let age = observedAt.map { now.timeIntervalSince($0) }
        let retained = windows.filter { window in
            if let resetsAt = window.resetsAt { return resetsAt > now }
            guard observationIsStale else { return true }
            guard let age, age.isFinite else { return false }
            return age >= 0 && age <= Self.maximumStaleRetention
        }
        guard retained.count != windows.count else { return self }

        var copy = self
        copy.windows = retained
        if retained.isEmpty {
            copy.status = .unavailable
            // The specific reason the collector already has leads to a clearer action.
            // Overwriting it with a generic "expired" would hide the operation actually needed.
            copy.note = note ?? expiredDataNote
        }
        return copy
    }

    private var expiredDataNote: String {
        switch id {
        case "claude-code":
            return "Claude usage data expired; sign in to Claude Code again, then check again"
        case "codex":
            return "Codex usage data expired; complete a Codex response, then check again"
        case "grok":
            return "Grok usage data expired; use Grok, then check again"
        default:
            return "Stored usage data expired; use the agent, then check again"
        }
    }

}

struct UsageSnapshot: Codable, Hashable {
    var updatedAt: Date
    var agents: [AgentUsage]
    /// The agent the user designated for priority display. If unspecified, decided automatically.
    var preferredAgentID: String?

    static let empty = UsageSnapshot(updatedAt: .distantPast, agents: [])

    func expiringStaleData(at now: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            updatedAt: updatedAt,
            agents: agents.map { $0.expiringStaleData(at: now) },
            preferredAgentID: preferredAgentID
        )
    }

    /// The single item shown in the headline. Decided in 3 stages:
    ///  1. The agent the user designated for priority
    ///  2. A short window like the 5-hour one (since it kicks in first)
    ///  3. The most constrained window overall
    var headline: (agent: AgentUsage, window: UsageWindow)? {
        let actionable = agents.filter {
            ($0.displayStatus == .ok || $0.displayStatus == .stale) && !$0.windows.isEmpty
        }

        if let preferredAgentID,
           let pinned = actionable.first(where: { $0.id == preferredAgentID }),
           let window = pinned.headlineWindow {
            return (agent: pinned, window: window)
        }

        let current = actionable.filter { $0.displayStatus == .ok }
        if let pick = automaticHeadline(in: current) { return pick }
        return automaticHeadline(in: actionable.filter { $0.displayStatus == .stale })
    }

    private func automaticHeadline(
        in candidates: [AgentUsage]
    ) -> (agent: AgentUsage, window: UsageWindow)? {
        let shortWindows = candidates.flatMap { agent in
            agent.windows.filter(\.isShortWindow).map { (agent: agent, window: $0) }
        }
        if let pick = shortWindows.max(by: { $0.window.usedPercent < $1.window.usedPercent }) {
            return pick
        }

        let all = candidates.flatMap { agent in
            agent.windows.map { (agent: agent, window: $0) }
        }
        return all.max { $0.window.usedPercent < $1.window.usedPercent }
    }

    /// A window other than the headline (e.g. 7d), belonging to the same agent as the headline.
    var headlineSecondary: UsageWindow? {
        guard let headline else { return nil }
        return headline.agent.windows.first { $0.id != headline.window.id }
    }
}
