import Foundation

/// Reads Claude's "Extra usage" (pay-as-you-go usage beyond the plan's allowance).
///
/// `/api/oauth/usage` (`ClaudeUsageAPI`) doesn't include this value. String analysis of the
/// claude.ai and Claude Code binaries confirmed a separate, org-scoped endpoint is used, but
/// the actual response has not been observed (this session wasn't granted permission to read
/// credentials from Keychain). Key names are guessed from static analysis and are unofficial and undocumented.
/// Confines the blast radius to this one file, so a format change doesn't break the whole app.
enum ClaudeExtraUsageAPI {
    struct Payload: Decodable, Sendable {
        let used_credits: Double?
        let monthly_limit: Double?
    }

    struct Snapshot: Sendable {
        let used: Double
        let limit: Double
    }

    private static let maximumResponseBytes = 256 * 1_024

    /// Not a value that changes often, so there's no need to poll it as frequently as the 5-hour window.
    private static let minimumInterval: TimeInterval = 15 * 60

    private actor Cache {
        private var snapshot: Snapshot?
        private var at: Date?

        func recentAttempt(after cutoff: Date) -> Snapshot?? {
            guard let at, at > cutoff else { return nil }
            return .some(snapshot)
        }

        func store(_ snapshot: Snapshot?, at date: Date) {
            self.snapshot = snapshot
            at = date
        }
    }

    private static let cache = Cache()

    /// - Parameter force: When "check again" is pressed, ask again without waiting for the interval.
    /// Leaves refreshing Keychain credentials to `ClaudeUsageAPI`; this just reads whatever is currently there.
    static func fetch(force: Bool = false, now: Date = Date()) async -> Snapshot? {
        if !force, let recent = await cache.recentAttempt(after: now - minimumInterval) {
            return recent
        }
        let snapshot = await fetchLive()
        await cache.store(snapshot, at: now)
        return snapshot
    }

    private static func fetchLive() async -> Snapshot? {
        guard case let .valid(credential) = ClaudeKeychain.credentialState() else { return nil }
        guard let organization = ClaudeWebUsageAPI.localOrganizationID() else { return nil }
        guard let url = URL(
            string: "https://api.anthropic.com/api/oauth/organizations/\(organization)/overage_spend_limit"
        ) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(
            "claude-code/\(ClaudeKeychain.installedVersion())",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= maximumResponseBytes
            else { return nil }
            let decoded = try JSONDecoder().decode(Payload.self, from: data)
            return validated(decoded)
        } catch {
            return nil
        }
    }

    /// A limit of 0 or less is treated as "Extra usage isn't enabled", so $0/$0 is never shown.
    static func validated(_ payload: Payload) -> Snapshot? {
        guard let used = payload.used_credits, used.isFinite, used >= 0,
              let limit = payload.monthly_limit, limit.isFinite, limit > 0
        else { return nil }
        return Snapshot(used: min(used, limit * 10), limit: limit)
    }
}
