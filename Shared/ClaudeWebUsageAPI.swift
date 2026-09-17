import Foundation

/// Reads usage from claude.ai's organization endpoint.
///
/// An optional route for environments with no Claude Code OAuth credentials (using only the
/// desktop app). Since this isn't a public API, it's used only when `ClaudeUsageAPI` can't get
/// credentials, and is never the default route.
///
/// The returned body has the same shape as `/api/oauth/usage` (`five_hour` / `seven_day` /
/// `seven_day_opus`), so decoding reuses `ClaudeUsageAPI.Payload` directly.
enum ClaudeWebUsageAPI {
    enum Failure: Sendable {
        case unauthorized
        case rateLimited(retryAt: Date?)
        /// A response that doesn't answer whether auth succeeded, e.g. a Cloudflare bot challenge.
        case challenged
        case organizationUnknown
        case networkOrServer
    }

    enum Result: Sendable {
        case success(ClaudeUsageAPI.Payload)
        case failure(Failure)
    }

    private static let base = "https://claude.ai/api"
    private static let maximumResponseBytes = 1 * 1_024 * 1_024
    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func fetch(sessionKey: String, now: Date = Date()) async -> Result {
        guard let organization = await organizationID(sessionKey: sessionKey) else {
            return .failure(.organizationUnknown)
        }
        guard let url = URL(string: "\(base)/organizations/\(organization)/usage") else {
            return .failure(.networkOrServer)
        }

        switch await perform(request(url: url, sessionKey: sessionKey)) {
        case let .body(data):
            guard let decoded = try? JSONDecoder().decode(ClaudeUsageAPI.Payload.self, from: data),
                  let payload = ClaudeUsageAPI.validated(decoded, now: now)
            else { return .failure(.networkOrServer) }
            return .success(payload)
        case let .failure(reason):
            return .failure(reason)
        }
    }

    // MARK: - Organization ID

    /// Checks `~/.claude.json` first. If already signed in to Claude, it has the organization ID,
    /// avoiding an extra request. Otherwise, pull it from the organization list.
    static func organizationID(sessionKey: String) async -> String? {
        if let local = localOrganizationID() { return local }

        guard let url = URL(string: "\(base)/organizations") else { return nil }
        guard case let .body(data) = await perform(request(url: url, sessionKey: sessionKey)),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        for row in rows {
            if let uuid = row["uuid"] as? String, isSafeIdentifier(uuid) { return uuid }
        }
        return nil
    }

    static func localOrganizationID() -> String? {
        guard let uuid = localAccount()?["organizationUuid"] as? String,
              isSafeIdentifier(uuid)
        else { return nil }
        return uuid
    }

    /// The subscription plan. Not included in the claude.ai route's response, so this pulls it from the sign-in record.
    /// It comes in as an identifier like `claude_pro`, so converting it to a display name is left to `PlanLabel`.
    static func localPlan() -> String? {
        localAccount()?["organizationType"] as? String
    }

    private static func localAccount() -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4 * 1_024 * 1_024 + 1),
              data.count <= 4 * 1_024 * 1_024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["oauthAccount"] as? [String: Any]
    }

    /// Allows only a UUID through. Since this value is spliced into a URL, this prevents the path from being rewritten.
    static func isSafeIdentifier(_ value: String) -> Bool {
        guard (8...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Requests

    private enum Response {
        case body(Data)
        case failure(Failure)
    }

    private static func request(url: URL, sessionKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    private static func perform(_ request: URLRequest) async -> Response {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.networkOrServer) }

            switch http.statusCode {
            case 200:
                guard data.count <= maximumResponseBytes else { return .failure(.networkOrServer) }
                // A bot challenge can return HTML with a 200 status. If it's not JSON, whether auth succeeded is unknown.
                guard data.first == UInt8(ascii: "{") || data.first == UInt8(ascii: "[")
                else { return .failure(.challenged) }
                return .body(data)
            case 401, 403:
                return .failure(.unauthorized)
            case 429:
                return .failure(.rateLimited(retryAt: retryDate(from: http)))
            case 503:
                return .failure(.challenged)
            default:
                return .failure(.networkOrServer)
            }
        } catch {
            return .failure(.networkOrServer)
        }
    }

    private static func retryDate(from response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds > 0, seconds <= 24 * 3_600
        else { return nil }
        return Date().addingTimeInterval(seconds)
    }
}
