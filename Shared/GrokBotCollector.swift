import Foundation

/// Grok Bot's remaining allowance.
///
/// Grok Bot doesn't write usage locally, so this queries cursor.com's
/// `get-sand-usage-status` (`sand` is Grok Bot's internal name).
/// Auth uses the cookie the user handed over by signing in inside the app.
/// This is a separate allowance from the existing Grok (CLI), and Grok Bot's own UI
/// explicitly states they're separate.
enum GrokBotCollector {

    struct Status: Decodable, Sendable {
        let usagePercent: Double?
        let currentPeriodStart: String?
        let nextResetTimestampUtc: String?
        let grokPlanLabel: String?
        let hasNonZeroIncludedLimit: Bool?
    }

    enum Outcome: Sendable {
        case status(Status)
        case unauthorized
        case unavailable
    }

    static func collect() async -> AgentUsage {
        guard let cookie = CursorSession.load() else {
            return AgentUsage(
                id: "grok-bot", name: "Grok Bot", plan: nil, windows: [],
                observedAt: nil, source: "usage API",
                status: installed ? .unavailable : .notInstalled,
                note: installed ? "Sign in to Grok Bot in Settings to read its usage" : nil
            )
        }

        switch await fetch(cookie: cookie) {
        case let .status(status):
            return agent(from: status)
        case .unauthorized:
            return AgentUsage(
                id: "grok-bot", name: "Grok Bot", plan: nil, windows: [],
                observedAt: nil, source: "usage API", status: .unavailable,
                note: "The saved Grok Bot sign-in was rejected; sign in again in Settings"
            )
        case .unavailable:
            return AgentUsage(
                id: "grok-bot", name: "Grok Bot", plan: nil, windows: [],
                observedAt: nil, source: "usage API", status: .unavailable,
                note: "Grok Bot usage could not be reached"
            )
        }
    }

    /// Confirms sign-in succeeded via the response. A check that avoids hardcoding a cookie name.
    static func sessionWorks(cookie: String) async -> Bool {
        if case .status = await fetch(cookie: cookie) { return true }
        return false
    }

    /// There's no point showing guidance in Settings in an environment where the app isn't installed.
    static var installed: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Grok Bot.app")
            || FileManager.default.fileExists(
                atPath: "\(NSHomeDirectory())/.grokbot"
            )
    }

    static func agent(from status: Status) -> AgentUsage {
        guard let used = status.usagePercent, used.isFinite, (0...100).contains(used),
              status.hasNonZeroIncludedLimit != false
        else {
            return AgentUsage(
                id: "grok-bot", name: "Grok Bot",
                plan: PlanLabel.normalize(status.grokPlanLabel), windows: [],
                observedAt: nil, source: "usage API", status: .unavailable,
                note: "Grok Bot usage could not be reached"
            )
        }

        let start = status.currentPeriodStart.flatMap(CursorAPI.parseISO8601)
        let reset = status.nextResetTimestampUtc.flatMap(CursorAPI.parseISO8601)
        let seconds = (start != nil && reset != nil)
            ? reset!.timeIntervalSince(start!)
            : nil

        // The period length isn't fixed (observed at roughly 3.5 days). Building a label from
        // its length would produce a number that doesn't match reality, so it's treated as a period, same as the existing Grok.
        let window = UsageWindow(
            id: "grokbot_period",
            label: "Period",
            usedPercent: used,
            resetsAt: reset,
            windowSeconds: (seconds.map { $0 > 0 } == true) ? seconds : nil
        )

        return AgentUsage(
            id: "grok-bot", name: "Grok Bot",
            plan: PlanLabel.normalize(status.grokPlanLabel),
            windows: [window], observedAt: Date(),
            source: "usage API", status: .ok, note: nil
        )
    }

    private static func fetch(cookie: String) async -> Outcome {
        switch await CursorAPI.post("get-sand-usage-status", cookie: cookie) {
        case let .body(data):
            guard let status = try? JSONDecoder().decode(Status.self, from: data)
            else { return .unavailable }
            return .status(status)
        case .unauthorized:
            return .unauthorized
        case .unavailable:
            return .unavailable
        }
    }
}
