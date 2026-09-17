import Foundation

/// Reads Codex's plan allowance by asking the official client itself.
///
/// The session log (rollout-*.jsonl) only grows when the terminal `codex` is used.
/// Using only the official app leaves it stuck on a stale value, so this asks
/// `codex app-server`'s JSON-RPC directly. It returns the same values as `/status`; no inference
/// runs, and nothing is written to `~/.codex`.
enum CodexAppServer {
    /// The cap from launch to response. Locally it typically returns in about a second.
    private static let responseTimeout: TimeInterval = 8

    /// The cap on how much to buffer while waiting for a response. Prevents unexpectedly chatty output from exhausting memory.
    private static let bufferLimit = 1 << 20

    private static let rateLimitsRequestID = 2

    /// Prevents the whole process from being killed by a write right after the other end exits.
    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Tries available executables in order. If the first one is old and doesn't know
    /// `account/rateLimits/read`, the other one might still work.
    static func executableCandidates() -> [URL] {
        let manager = FileManager.default
        var candidates: [URL] = []
        if let located = CLILocator.locate("codex") { candidates.append(located) }

        // The official app bundles its own codex. It's here even for people who haven't installed the CLI.
        for path in [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/ChatGPT.app/Contents/Resources/codex",
        ] where manager.isExecutableFile(atPath: path) {
            candidates.append(URL(fileURLWithPath: path))
        }
        return candidates
    }

    static var isAvailable: Bool { !executableCandidates().isEmpty }

    /// The main app updates every minute, but weekly or 5-hour windows don't need that granularity.
    /// To avoid launching a process and querying externally every minute, reuse the previous answer up to this interval.
    private static let minimumInterval: TimeInterval = 5 * 60

    private static let cache = Cache()

    /// The shape the caller (CodexCollector) receives. resetCreditsAvailable is a top-level
    /// value in the response not tied to any bucket, so it's kept separate from observations.
    struct Snapshot {
        let observations: [CodexCollector.Observation]
        let resetCreditsAvailable: Int?
    }

    /// - Parameter force: When "check again" is pressed, ask again without waiting for the interval.
    static func snapshot(force: Bool = false, now: Date = Date()) -> Snapshot? {
        // Failures count toward the interval too. There's nothing to gain from launching this every minute before sign-in, for example.
        if !force, let recent = cache.recentAttempt(after: now - minimumInterval) {
            return recent?.snapshot
        }
        for executable in executableCandidates() {
            if let result = rateLimits(using: executable), !result.buckets.isEmpty {
                let answer = Answer(
                    buckets: result.buckets, observedAt: now,
                    resetCreditsAvailable: result.resetCreditsAvailable
                )
                cache.store(answer, at: now)
                return answer.snapshot
            }
        }
        cache.store(nil, at: now)
        return nil
    }

    private struct Answer {
        let buckets: [CodexCollector.RateLimits]
        let observedAt: Date
        let resetCreditsAvailable: Int?

        var snapshot: Snapshot {
            Snapshot(
                observations: buckets.map { .init(limits: $0, observedAt: observedAt) },
                resetCreditsAvailable: resetCreditsAvailable
            )
        }
    }

    /// Collection runs on a separate task from the main one, so this is held behind a lock.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var attemptedAt: Date?
        private var answer: Answer?

        /// If there was a recent attempt, returns its result (the answer on success, nil on failure) as a nested Optional.
        /// An outer nil means "hasn't been tried yet, so go ask".
        func recentAttempt(after cutoff: Date) -> Answer?? {
            lock.lock()
            defer { lock.unlock() }
            guard let attemptedAt, attemptedAt > cutoff else { return nil }
            return .some(answer)
        }

        func store(_ answer: Answer?, at date: Date) {
            lock.lock()
            self.answer = answer
            attemptedAt = date
            lock.unlock()
        }
    }

    // MARK: - JSON-RPC

    private struct RateLimitsResult {
        let buckets: [CodexCollector.RateLimits]
        let resetCreditsAvailable: Int?
    }

    private static func rateLimits(using executable: URL) -> RateLimitsResult? {
        _ = ignoreBrokenPipe

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Progress and warnings would block without a reader, so discard them.
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        // Don't keep waiting on a side that never responds. terminate delivers EOF to the reader.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + responseTimeout, execute: watchdog)
        defer {
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }

        // Without going through initialize, other methods are rejected with "Not initialized".
        let handshake = """
        {"jsonrpc":"2.0","id":1,"method":"initialize",\
        "params":{"clientInfo":{"name":"AI Usage","version":"\(clientVersion)"}}}
        {"jsonrpc":"2.0","id":\(rateLimitsRequestID),"method":"account/rateLimits/read"}

        """
        guard let request = handshake.data(using: .utf8),
              (try? input.fileHandleForWriting.write(contentsOf: request)) != nil
        else { return nil }

        return readResponse(from: output.fileHandleForReading)
    }

    /// Line-delimited JSON. Notifications can arrive between responses to requests, so select by id.
    private static func readResponse(from handle: FileHandle) -> RateLimitsResult? {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let result = decodedResult(fromResponseLine: line) else { continue }
                return result
            }
            if buffer.count > bufferLimit { return nil }
        }
    }

    /// Reads one line and returns the bucket and resetCredits if it's the response being awaited. nil for a notification or other response.
    /// An empty array if the response was an error — the caller gives up at that point.
    private static func decodedResult(fromResponseLine line: Data) -> RateLimitsResult? {
        guard let message = try? JSONDecoder().decode(Response.self, from: line),
              message.id == rateLimitsRequestID
        else { return nil }
        return RateLimitsResult(
            buckets: message.result?.buckets ?? [],
            resetCreditsAvailable: message.result?.rateLimitResetCredits?.availableCount
        )
    }

    /// A compatibility API called directly by tests. Extracts only the buckets.
    static func buckets(fromResponseLine line: Data) -> [CodexCollector.RateLimits]? {
        decodedResult(fromResponseLine: line)?.buckets
    }

    /// For tests. Extracts only resetCredits.
    static func resetCreditsAvailable(fromResponseLine line: Data) -> Int? {
        decodedResult(fromResponseLine: line)?.resetCreditsAvailable
    }

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Response shape

    /// The log uses snake_case; this returns the same content in camelCase.
    /// To avoid maintaining the display side twice, it's converted to match the log's type at read time.
    struct Response: Decodable {
        struct Result: Decodable {
            /// The reset-credits summary at the top level of an `account/rateLimits/read` response.
            /// The shape as confirmed from the generated protocol schema (`codex app-server generate-json-schema`).
            /// Not unofficial, but an undocumented internal contract — kept independent from other
            /// fields so that if the key changes, this quietly falls back to nil instead of breaking anything else.
            struct ResetCreditsSummary: Decodable {
                let availableCount: Int?
            }

            let rateLimits: Bucket?
            let rateLimitsByLimitId: [String: Bucket]?
            let rateLimitResetCredits: ResetCreditsSummary?

            /// Even on an older version that doesn't send a bucket list, this lets at least the representative one be picked up.
            var buckets: [CodexCollector.RateLimits] {
                let all = rateLimitsByLimitId.map { Array($0.values) } ?? rateLimits.map { [$0] } ?? []
                return all.map(\.asRateLimits)
            }
        }

        struct Bucket: Decodable {
            struct Window: Decodable {
                let usedPercent: Double?
                let windowDurationMins: Int?
                let resetsAt: Double?

                var asWindow: CodexCollector.RateLimits.Window {
                    .init(used_percent: usedPercent,
                          window_minutes: windowDurationMins,
                          resets_at: resetsAt)
                }
            }

            let limitId: String?
            let limitName: String?
            let planType: String?
            let primary: Window?
            let secondary: Window?

            var asRateLimits: CodexCollector.RateLimits {
                .init(primary: primary?.asWindow,
                      secondary: secondary?.asWindow,
                      plan_type: planType,
                      limit_id: limitId,
                      limit_name: limitName)
            }
        }

        let id: Int?
        let result: Result?
    }
}
