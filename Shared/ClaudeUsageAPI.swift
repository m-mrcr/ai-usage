import Foundation

/// The same OAuth endpoint Claude Code's `/usage` hits.
///
/// Unlike statusLine, this can get the current value even when Claude Code isn't running.
/// However, without a User-Agent of `claude-code/<version>` it falls into a strict 429 bucket,
/// so the headers are matched and requests are capped to at most every 180 seconds.
actor ClaudeUsageAPI {
    static let shared = ClaudeUsageAPI()

    struct Window: Decodable, Sendable {
        let utilization: Double?
        let resets_at: String?

        var resetDate: Date? {
            guard let resets_at else { return nil }
            return ClaudeUsageAPI.parseISO8601(resets_at)
        }
    }

    struct Payload: Decodable, Sendable {
        let five_hour: Window?
        let seven_day: Window?
        let seven_day_opus: Window?
    }

    struct FetchResult: Sendable {
        let payload: Payload
        let observedAt: Date
        let plan: String?
        /// The last request failed, or it's been 6+ hours since the real measurement.
        let isStale: Bool
        /// The most recent failure reason, when the cache is being shown as Stale.
        let failureReason: FailureReason?
    }

    enum FailureReason: Sendable {
        case credentialUnavailable
        case credentialExpired
        /// Signed in to Claude, but the CLI's OAuth token isn't in Keychain.
        /// Using only the desktop app leaves this state unchanged.
        case terminalSignInRequired
        /// Expired, but refreshing is left to the terminal CLI.
        /// The refresh token rotates, so it isn't refreshed from two places.
        case refreshDeferredToCLI
        /// The configured session key was rejected by claude.ai.
        case sessionKeyRejected
        case unauthorized
        case rateLimited
        case networkOrServer
    }

    enum FetchResponse: Sendable {
        case result(FetchResult)
        case unavailable(FailureReason)
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// A 180-second TTL. Even when called from a 60-second refresh loop, actual requests happen only once every 3 minutes.
    private static let minimumInterval: TimeInterval = 180
    private static let staleInterval: TimeInterval = 6 * 3_600
    private static let maximumBackoff: TimeInterval = 30 * 60
    private static let maximumResponseBytes = 1 * 1_024 * 1_024

    private struct Cache {
        let payload: Payload
        let at: Date
        let plan: String?
    }

    private enum AttemptOutcome: Sendable {
        case success(Payload, plan: String?)
        case rateLimited(retryAt: Date?)
        case credentialUnavailable
        /// Denied at Keychain's permission dialog, or there was no response.
        case keychainAccessDenied
        case credentialExpired
        case terminalSignInRequired
        case refreshDeferredToCLI
        case unauthorized
        case forbidden
        case failed
        /// The configured session key was rejected. It needs to be pasted in again.
        case sessionKeyRejected
    }

    private var cached: Cache?
    private var nextAttemptAt: Date?
    private var consecutiveFailures = 0
    private var lastFailure: FailureReason?
    private var inFlight: (id: UUID, task: Task<AttemptOutcome, Never>)?

    /// The most recent fetch result. Returns the cache if the request can't be made, or the failure reason if there's no cache.
    func fetch(force: Bool = false) async -> FetchResponse {
        let now = Date()

        // An actor can be reentered during an await, so explicitly share an in-flight request.
        if let inFlight {
            return await completeAttempt(id: inFlight.id, task: inFlight.task)
        }

        if !force, let cached {
            let age = now.timeIntervalSince(cached.at)
            if age.isFinite, age >= 0, age < Self.minimumInterval {
                return cachedResponse(now: now, forceStale: lastFailure != nil)
            }
        }
        let providerBackoffMustBeHonored: Bool
        if case .rateLimited? = lastFailure { providerBackoffMustBeHonored = true }
        else { providerBackoffMustBeHonored = false }
        if let nextAttemptAt, now < nextAttemptAt,
           !force || providerBackoffMustBeHonored {
            return cachedResponse(now: now, forceStale: true)
        }

        let id = UUID()
        let task = Task {
            await Self.prepareCredentialAndPerform()
        }
        inFlight = (id, task)
        return await completeAttempt(id: id, task: task)
    }

    private func completeAttempt(id: UUID, task: Task<AttemptOutcome, Never>) async -> FetchResponse {
        let outcome = await task.value
        let now = Date()

        // Of multiple callers awaiting the same Task, only the first one back on the actor applies the result.
        if inFlight?.id == id {
            inFlight = nil
            apply(outcome, now: now)
        }
        return cachedResponse(now: now, forceStale: lastFailure != nil)
    }

    private func apply(_ outcome: AttemptOutcome, now: Date) {
        switch outcome {
        case let .success(payload, plan):
            cached = Cache(payload: payload, at: now, plan: plan)
            consecutiveFailures = 0
            nextAttemptAt = nil
            lastFailure = nil

        case let .rateLimited(retryAt):
            consecutiveFailures += 1
            let floor = now.addingTimeInterval(Self.minimumInterval)
            nextAttemptAt = max(retryAt ?? now.addingTimeInterval(600), floor)
            lastFailure = .rateLimited

        case .credentialUnavailable:
            recordFailure(now: now, reason: .credentialUnavailable)

        case .keychainAccessDenied:
            // Asking again on every periodic refresh would keep showing a dialog the user already dismissed.
            // Ask again only on a user action such as "check again" (force).
            consecutiveFailures += 1
            nextAttemptAt = .distantFuture
            lastFailure = .credentialUnavailable

        case .credentialExpired:
            recordFailure(now: now, reason: .credentialExpired)

        case .terminalSignInRequired:
            recordFailure(now: now, reason: .terminalSignInRequired)

        case .refreshDeferredToCLI:
            recordFailure(now: now, reason: .refreshDeferredToCLI)

        case .sessionKeyRejected:
            recordFailure(now: now, reason: .sessionKeyRejected)

        case .unauthorized:
            consecutiveFailures += 1
            nextAttemptAt = now.addingTimeInterval(15 * 60)
            lastFailure = .unauthorized

        case .forbidden:
            consecutiveFailures += 1
            nextAttemptAt = now.addingTimeInterval(15 * 60)
            lastFailure = .unauthorized

        case .failed:
            recordFailure(now: now, reason: .networkOrServer)
        }
    }

    private func recordFailure(now: Date, reason: FailureReason) {
        consecutiveFailures += 1
        let exponent = min(max(consecutiveFailures - 1, 0), 4)
        let delay = min(
            Self.maximumBackoff,
            Self.minimumInterval * pow(2, Double(exponent))
        )
        nextAttemptAt = now.addingTimeInterval(delay)
        lastFailure = reason
    }

    private func cachedResponse(now: Date, forceStale: Bool) -> FetchResponse {
        guard let cached else {
            return .unavailable(lastFailure ?? .networkOrServer)
        }
        let age = now.timeIntervalSince(cached.at)
        return .result(FetchResult(
            payload: cached.payload,
            observedAt: cached.at,
            plan: cached.plan,
            isStale: forceStale || !age.isFinite || age < 0 || age > Self.staleInterval,
            failureReason: forceStale ? lastFailure : nil
        ))
    }

    private static func prepareCredentialAndPerform() async -> AttemptOutcome {
        let credential: ClaudeKeychain.OAuthCredential
        switch ClaudeKeychain.credentialState() {
        case let .valid(current):
            credential = current

        case let .refreshable(expired):
            // If the CLI is present, don't write back — avoid fighting over it and leave refreshing to the CLI.
            // But if the CLI hasn't been used in a while, a stale expired value can linger, so
            // read from the session key instead, if one is set.
            if ClaudeKeychain.terminalCLIInstalled() {
                return await sessionKeyOutcome() ?? .refreshDeferredToCLI
            }
            switch await ClaudeOAuthRefresher.refresh(expired) {
            case let .credential(refreshed):
                credential = refreshed
            case let .rateLimited(retryAt):
                return .rateLimited(retryAt: retryAt)
            case .unauthorized:
                return .credentialExpired
            case .keychainUnavailable:
                return .credentialUnavailable
            case .temporarilyUnavailable:
                return .failed
            case .networkOrServer:
                return .failed
            }

        case let .unavailable(failure):
            // An optional route for environments with no OAuth credentials (e.g. desktop app only).
            // Used only if configured, and never touches Claude Code's Keychain item.
            // There's nothing more the OAuth side can do here, so report the session key side's failure reason as-is.
            if let outcome = await sessionKeyOutcome(reportingFailure: true) { return outcome }
            switch failure {
            case .expired:
                return .credentialExpired
            case .notLinked:
                return .terminalSignInRequired
            case .notFound:
                // If already signed in to Claude, all that's missing is the terminal CLI sign-in.
                return ClaudeKeychain.hasSignedInAccount()
                    ? .terminalSignInRequired
                    : .credentialUnavailable
            case .accessDenied:
                return .keychainAccessDenied
            case .malformed:
                return .credentialUnavailable
            }
        }

        let first = await perform(
            usageRequest(for: credential),
            plan: credential.subscriptionType
        )
        guard case .unauthorized = first, credential.refreshToken != nil else {
            return first
        }
        if ClaudeKeychain.terminalCLIInstalled() {
            return await sessionKeyOutcome() ?? .refreshDeferredToCLI
        }

        // On a 401, reload Keychain, and if there's no sibling update, force a refresh and retry exactly once.
        switch await ClaudeOAuthRefresher.refresh(credential, force: true) {
        case let .credential(refreshed):
            return await perform(
                usageRequest(for: refreshed),
                plan: refreshed.subscriptionType
            )
        case let .rateLimited(retryAt):
            return .rateLimited(retryAt: retryAt)
        case .unauthorized:
            return await sessionKeyOutcome() ?? .credentialExpired
        case .keychainUnavailable:
            return await sessionKeyOutcome() ?? .credentialUnavailable
        case .temporarilyUnavailable:
            return .failed
        case .networkOrServer:
            return .failed
        }
    }

    /// Reads with the configured session key. nil if none is set.
    ///
    /// In a scenario where OAuth still has options left (e.g. the CLI can refresh it), a failure here
    /// still returns nil and defers to OAuth's guidance. The key's rejection should only be
    /// surfaced when OAuth is out of options and this route was the last resort.
    private static func sessionKeyOutcome(
        reportingFailure: Bool = false
    ) async -> AttemptOutcome? {
        guard let key = ClaudeSessionKey.load() else { return nil }
        switch await ClaudeWebUsageAPI.fetch(sessionKey: key) {
        case let .success(payload):
            return .success(payload, plan: ClaudeWebUsageAPI.localPlan())
        case let .failure(reason):
            guard reportingFailure else { return nil }
            switch reason {
            case .unauthorized:
                return .sessionKeyRejected
            case let .rateLimited(retryAt):
                return .rateLimited(retryAt: retryAt)
            case .challenged, .organizationUnknown, .networkOrServer:
                return .failed
            }
        }
    }

    private static func usageRequest(
        for credential: ClaudeKeychain.OAuthCredential
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(
            "claude-code/\(ClaudeKeychain.installedVersion())",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        return request
    }

    private static func perform(_ request: URLRequest, plan: String?) async -> AttemptOutcome {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            let status = http.statusCode

            if status == 429 {
                return .rateLimited(retryAt: retryDate(from: http, now: Date()))
            }
            if status == 401 { return .unauthorized }
            if status == 403 { return .forbidden }
            guard status == 200, data.count <= maximumResponseBytes else { return .failed }

            let decoded = try JSONDecoder().decode(Payload.self, from: data)
            guard let payload = validated(decoded, now: Date()) else { return .failed }
            return .success(payload, plan: plan)
        } catch {
            return .failed
        }
    }

    static func validated(_ payload: Payload, now: Date) -> Payload? {
        func validWindow(_ window: Window?) -> Window? {
            guard let window,
                  let utilization = window.utilization,
                  utilization.isFinite,
                  (0...100).contains(utilization)
            else { return nil }

            if window.resets_at != nil {
                guard let date = window.resetDate else { return nil }
                let distance = date.timeIntervalSince(now)
                guard distance.isFinite, abs(distance) <= 10 * 365 * 86_400 else { return nil }
            }
            return window
        }

        let result = Payload(
            five_hour: validWindow(payload.five_hour),
            seven_day: validWindow(payload.seven_day),
            seven_day_opus: validWindow(payload.seven_day_opus)
        )
        guard result.five_hour != nil || result.seven_day != nil || result.seven_day_opus != nil
        else { return nil }
        return result
    }

    private static func retryDate(from response: HTTPURLResponse, now: Date) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        if let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(min(seconds, 7 * 86_400))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let parsed = formatter.date(from: raw) else { return nil }
        return min(max(parsed, now), now.addingTimeInterval(7 * 86_400))
    }
}
