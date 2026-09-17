import Foundation

enum UsageCollector {
    static func collectAll(order: [String] = [], force: Bool = false) async -> UsageSnapshot {
        var agents = [
            await ClaudeCollector.collect(force: force),
            CodexCollector.collect(force: force),
            GrokCollector.collect(),
            await GrokBotCollector.collect(),
            await CursorCollector.collect(),
        ]

        // Arranged in the order the user rearranged them. Anything not registered stays at the back in its original order.
        if !order.isEmpty {
            agents = agents.enumerated().sorted { lhs, rhs in
                let l = order.firstIndex(of: lhs.element.id) ?? (order.count + lhs.offset)
                let r = order.firstIndex(of: rhs.element.id) ?? (order.count + rhs.offset)
                return l < r
            }.map(\.element)
        }

        // Under automatic ordering, nothing is pinned — left to the short-window-then-severity judgment.
        // Only when the user has rearranged things does the first agent with real data become the headline.
        let headliner = order.isEmpty ? nil : agents.first { !$0.windows.isEmpty }?.id

        return UsageSnapshot(updatedAt: Date(), agents: agents,
                             preferredAgentID: headliner)
    }

}
