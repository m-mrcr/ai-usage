import Foundation

/// Grok's remaining allowance.
///
/// Grok writes `billing: fetched credits config` into `~/.grok/logs/unified.jsonl`.
/// It contains `creditUsagePercent` (omitted when 0) and the weekly period's end time.
enum GrokCollector {
    private static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".grok/logs/unified.jsonl")

    private static let tailBytes = 2 * 1_024 * 1_024

    static func collect() -> AgentUsage {
        let installed = FileManager.default.fileExists(
            atPath: "\(NSHomeDirectory())/.grok"
        )
        guard installed else {
            return AgentUsage(id: "grok", name: "Grok", plan: nil, windows: [],
                              observedAt: nil, source: "billing log",
                              status: .notInstalled, note: nil)
        }

        guard let hit = latestBilling() else {
            return AgentUsage(id: "grok", name: "Grok", plan: nil, windows: [],
                              observedAt: nil, source: "billing log",
                              status: .unavailable,
                              note: "Run Grok once to populate its billing log")
        }

        // creditUsagePercent is omitted when 0, so a missing value is treated as 0.
        let window = UsageWindow(
            id: "grok_period",
            label: hit.isWeekly ? "7d" : "Period",
            usedPercent: hit.usedPercent,
            resetsAt: hit.periodEnd,
            windowSeconds: hit.isWeekly ? 7 * 86_400 : nil
        )

        let isStale = Date().timeIntervalSince(hit.observedAt) > 6 * 3_600

        return AgentUsage(
            id: "grok",
            name: "Grok",
            plan: PlanLabel.normalize(hit.tier),
            windows: [window],
            observedAt: hit.observedAt,
            source: "billing log",
            status: isStale ? .stale : .ok,
            note: nil
        )
    }

    private struct Billing {
        let usedPercent: Double
        let periodEnd: Date?
        let isWeekly: Bool
        let tier: String?
        let observedAt: Date
    }

    private static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func latestBilling() -> Billing? {
        guard let data = readTail(of: logURL, maximumBytes: tailBytes) else { return nil }

        for rawLine in data.split(separator: 0x0A).reversed() {
            guard let line = String(data: Data(rawLine), encoding: .utf8) else { continue }
            guard line.contains("fetched credits config"),
                  let lineData = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let context = root["ctx"] as? [String: Any],
                  let config = context["config"] as? [String: Any]
            else { continue }

            guard let period = config["currentPeriod"] as? [String: Any],
                  let periodType = period["type"] as? String,
                  !periodType.isEmpty,
                  let periodEnd = plausibleResetDate(
                      parseDate(period["end"] as? String)
                          ?? parseDate(config["billingPeriodEnd"] as? String)
                  )
            else { continue }
            guard let observedAt = parseDate(root["ts"] as? String),
                  isPlausibleObservedAt(observedAt)
            else { continue }

            let usedPercent: Double
            if let rawUsed = config["creditUsagePercent"] {
                guard let parsed = number(rawUsed),
                      parsed.isFinite,
                      (0...100).contains(parsed)
                else { continue }
                usedPercent = parsed
            } else {
                // The current Grok only omits the field itself when it's 0.
                usedPercent = 0
            }

            return Billing(
                usedPercent: usedPercent,
                periodEnd: periodEnd,
                isWeekly: periodType.uppercased().contains("WEEKLY"),
                tier: context["subscriptionTier"] as? String,
                observedAt: observedAt
            )
        }
        return nil
    }

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

    private static func number(_ value: Any) -> Double? {
        guard !(value is Bool), let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }

    private static func isPlausibleObservedAt(_ date: Date) -> Bool {
        let distance = date.timeIntervalSinceNow
        return distance.isFinite
            && distance >= -10 * 365 * 86_400
            && distance <= 5 * 60
    }

    private static func plausibleResetDate(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let distance = date.timeIntervalSinceNow
        guard distance.isFinite,
              distance >= -370 * 86_400,
              distance <= 10 * 365 * 86_400
        else { return nil }
        return date
    }
}
