import Foundation
import Darwin

/// Refreshes an expired access token at the same OAuth token endpoint Claude Code uses.
/// Since the refresh token rotates, this honors Claude Code's lock and Keychain's CAS conditions.
enum ClaudeOAuthRefresher {
    enum Outcome: Sendable {
        case credential(ClaudeKeychain.OAuthCredential)
        case rateLimited(retryAt: Date?)
        case unauthorized
        case keychainUnavailable
        case temporarilyUnavailable
        case networkOrServer
    }

    private struct RefreshPayload: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
        let scope: [String]?

        private enum CodingKeys: String, CodingKey {
            case access_token, refresh_token, expires_in, scope
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            access_token = try values.decode(String.self, forKey: .access_token)
            refresh_token = try values.decodeIfPresent(String.self, forKey: .refresh_token)
            expires_in = try values.decode(Double.self, forKey: .expires_in)
            if let text = try? values.decode(String.self, forKey: .scope) {
                scope = text.split(whereSeparator: \.isWhitespace).map(String.init)
            } else {
                scope = try? values.decode([String].self, forKey: .scope)
            }
        }
    }

    private enum TokenReply {
        case payload(RefreshPayload)
        case invalidScope
        case rateLimited(retryAt: Date?)
        case unauthorized
        case failed
    }

    private static let tokenURL = URL(
        string: "https://platform.claude.com/v1/oauth/token"
    )!
    private static let defaultClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let maximumResponseBytes = 1 * 1_024 * 1_024

    static func refresh(
        _ original: ClaudeKeychain.OAuthCredential,
        force: Bool = false
    ) async -> Outcome {
        guard let lock = await ClaudeOAuthRefreshLock.acquire() else {
            return .temporarilyUnavailable
        }

        let outcome = await refreshWhileLocked(original, force: force, lock: lock)
        await lock.release()
        return outcome
    }

    private static func refreshWhileLocked(
        _ original: ClaudeKeychain.OAuthCredential,
        force: Bool,
        lock: ClaudeOAuthRefreshLock
    ) async -> Outcome {
        guard lock.isValid else { return .temporarilyUnavailable }

        // If Claude Code already refreshed it first, defer to that sibling write.
        let current: ClaudeKeychain.OAuthCredential
        switch ClaudeKeychain.credentialState() {
        case let .valid(credential):
            if shouldReuseCurrentAccessToken(
                credential.accessToken,
                originalAccessToken: original.accessToken,
                force: force
            ) {
                return .credential(credential)
            }
            current = credential
        case let .refreshable(credential):
            // Even from a sibling write, if it's near or past expiry, continue refreshing based on that latest token.
            current = credential
        case .unavailable:
            return .keychainUnavailable
        }

        guard lock.isValid,
              let refreshToken = current.refreshToken,
              ClaudeKeychain.prepareForRefresh(current)
        else { return .keychainUnavailable }

        let storedScopes = validatedScopes(current.scopes) ?? []
        let shouldExpandDefaultScopes = current.clientID == nil
            && (storedScopes.contains("user:inference") || current.subscriptionType != nil)
        let requestScopes = shouldExpandDefaultScopes
            ? expandedDefaultScopes(from: storedScopes)
            : (storedScopes.isEmpty ? defaultScopes : storedScopes)

        var effectiveRequestScopes = requestScopes
        var reply = await requestToken(
            refreshToken: refreshToken,
            clientID: current.clientID ?? defaultClientID,
            scopes: effectiveRequestScopes
        )
        if case .invalidScope = reply,
           shouldExpandDefaultScopes,
           storedScopes.contains("user:inference"),
           storedScopes != requestScopes {
            // As with Claude itself, retry once with the original stored scopes only if the default expansion was rejected.
            effectiveRequestScopes = storedScopes
            reply = await requestToken(
                refreshToken: refreshToken,
                clientID: current.clientID ?? defaultClientID,
                scopes: effectiveRequestScopes
            )
        }

        // If Claude replaced the stale lock during the request, don't write to the now-conflicting Keychain.
        guard lock.isValid else { return .temporarilyUnavailable }

        switch reply {
        case let .payload(payload):
            let rotatedRefreshToken = payload.refresh_token ?? refreshToken
            let expiresAt = Date().addingTimeInterval(payload.expires_in)
            // The token has already rotated by this point, so don't abandon the write-back just
            // because the response scope is missing or invalid — save the request scope that actually succeeded.
            let responseScopes = scopesForPersistence(
                responseScopes: payload.scope,
                effectiveRequestScopes: effectiveRequestScopes
            )
            switch ClaudeKeychain.saveRefreshedCredential(
                expected: current,
                accessToken: payload.access_token,
                refreshToken: rotatedRefreshToken,
                expiresAt: expiresAt,
                scopes: responseScopes
            ) {
            case .saved:
                if case let .valid(credential) = ClaudeKeychain.credentialState(refreshSkew: 0) {
                    return .credential(credential)
                }
                return .keychainUnavailable
            case let .changed(state):
                if case let .valid(credential) = state { return .credential(credential) }
                return .keychainUnavailable
            case .failed:
                // If saving fails after rotation, Claude Code is left holding the stale token too, so don't treat this as success.
                return .keychainUnavailable
            }

        case let .rateLimited(retryAt):
            return .rateLimited(retryAt: retryAt)
        case .invalidScope, .unauthorized:
            return .unauthorized
        case .failed:
            return .networkOrServer
        }
    }

    private static func requestToken(
        refreshToken: String,
        clientID: String,
        scopes: [String]
    ) async -> TokenReply {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": scopes.joined(separator: " "),
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let encoded = try? JSONSerialization.data(withJSONObject: body)
        else { return .failed }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.httpBody = encoded
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  data.count <= maximumResponseBytes
            else { return .failed }
            if http.statusCode == 429 {
                return .rateLimited(retryAt: retryDate(from: http, now: Date()))
            }
            if http.statusCode == 400, oauthErrorCode(in: data) == "invalid_scope" {
                return .invalidScope
            }
            if [400, 401, 403].contains(http.statusCode) { return .unauthorized }
            guard http.statusCode == 200,
                  let payload = try? JSONDecoder().decode(RefreshPayload.self, from: data),
                  payload.expires_in.isFinite,
                  (60...7 * 86_400).contains(payload.expires_in)
            else { return .failed }
            return .payload(payload)
        } catch {
            return .failed
        }
    }

    /// OAuth errors appear as either {"error":"code"} or {"error":{"type":"code"}}.
    static func oauthErrorCode(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let code = root["error"] as? String { return code }
        return (root["error"] as? [String: Any])?["type"] as? String
    }

    static func expandedDefaultScopes(from stored: [String]) -> [String] {
        let expansionScopes = Set([
            "user:projects:read",
            "user:projects:write",
            "user:plugins",
        ])
        var result = defaultScopes
        for scope in stored where expansionScopes.contains(scope) && !result.contains(scope) {
            result.append(scope)
        }
        return result
    }

    /// A normal refresh reuses the current valid value. Only on a forced refresh triggered by the
    /// usage API returning 401 does it proceed to refresh even with the same access token. A sibling process's updated value is always adopted.
    static func shouldReuseCurrentAccessToken(
        _ currentAccessToken: String,
        originalAccessToken: String,
        force: Bool
    ) -> Bool {
        currentAccessToken != originalAccessToken || !force
    }

    static func scopesForPersistence(
        responseScopes: [String]?,
        effectiveRequestScopes: [String]
    ) -> [String] {
        guard let responseScopes else { return effectiveRequestScopes }
        return validatedScopes(responseScopes) ?? effectiveRequestScopes
    }

    private static func validatedScopes(_ scopes: [String]) -> [String]? {
        guard !scopes.isEmpty, scopes.count <= 32 else { return nil }
        var result: [String] = []
        for scope in scopes {
            guard !scope.isEmpty, scope.utf8.count <= 128,
                  scope.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.value {
                      case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
                           0x2D, 0x2E, 0x3A, 0x5F:
                          return true
                      default:
                          return false
                      }
                  })
            else { return nil }
            if !result.contains(scope) { result.append(scope) }
        }
        return result
    }

    private static let defaultScopes = [
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload",
    ]

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

/// A short-lived lock that avoids conflicting with the refresh lock used by Claude Code 2.x.
/// If the second lock can't be acquired, immediately release the first one, to avoid a deadlock.
final class ClaudeOAuthRefreshLock: @unchecked Sendable {
    private final class HeartbeatState: @unchecked Sendable {
        private let lock = NSLock()
        private var compromised = false

        func markCompromised() {
            lock.lock()
            compromised = true
            lock.unlock()
        }

        var isCompromised: Bool {
            lock.lock()
            defer { lock.unlock() }
            return compromised
        }
    }

    private struct Entry: Sendable {
        let url: URL
        let descriptor: Int32
        let device: dev_t
        let inode: ino_t
    }

    private let entries: [Entry]
    private let heartbeatState: HeartbeatState
    private var heartbeatTask: Task<Void, Never>?

    private init(entries: [Entry]) {
        let heartbeatState = HeartbeatState()
        self.entries = entries
        self.heartbeatState = heartbeatState
        heartbeatTask = Task.detached(priority: .utility) {
            let descriptors = entries.map(\.descriptor)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                for descriptor in descriptors {
                    guard Darwin.futimens(descriptor, nil) == 0 else {
                        heartbeatState.markCompromised()
                        return
                    }
                }
            }
        }
    }

    static func acquire(
        directory suppliedDirectory: URL? = nil,
        attempts: Int = 6,
        retryMilliseconds: ClosedRange<Int> = 1_000...2_000
    ) async -> ClaudeOAuthRefreshLock? {
        let manager = FileManager.default
        let directory = (suppliedDirectory ?? manager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true))
            .resolvingSymlinksInPath()
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = [
            directory.appendingPathComponent(".oauth_refresh.lock", isDirectory: true),
            URL(fileURLWithPath: directory.path + ".lock", isDirectory: true),
        ]

        let boundedAttempts = min(max(attempts, 1), 6)
        for attempt in 0..<boundedAttempts {
            var acquired: [Entry] = []
            for url in urls {
                if let entry = acquire(url) {
                    acquired.append(entry)
                } else {
                    release(acquired)
                    acquired.removeAll()
                    break
                }
            }
            if acquired.count == urls.count {
                return ClaudeOAuthRefreshLock(entries: acquired)
            }
            guard attempt < boundedAttempts - 1 else { break }
            let milliseconds = Int.random(in: retryMilliseconds)
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }
        return nil
    }

    var isValid: Bool {
        guard !heartbeatState.isCompromised else { return false }
        for entry in entries {
            var descriptorInfo = stat()
            guard Darwin.fstat(entry.descriptor, &descriptorInfo) == 0,
                  descriptorInfo.st_dev == entry.device,
                  descriptorInfo.st_ino == entry.inode,
                  let pathInfo = Self.fileInfo(at: entry.url),
                  pathInfo.st_dev == entry.device,
                  pathInfo.st_ino == entry.inode
            else { return false }
        }
        return true
    }

    func release() async {
        heartbeatTask?.cancel()
        await heartbeatTask?.value
        heartbeatTask = nil
        Self.release(entries)
    }

    private static func acquire(_ url: URL) -> Entry? {
        if let info = fileInfo(at: url),
           Date().timeIntervalSince1970 - modificationTime(of: info) > 60 {
            // Claude itself also rmdirs an empty directory. If it has contents, ownership is unclear, so leave it alone.
            _ = url.path.withCString { Darwin.rmdir($0) }
        }

        guard url.path.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0 else {
            return nil
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            _ = url.path.withCString { Darwin.rmdir($0) }
            return nil
        }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR
        else {
            Darwin.close(descriptor)
            _ = url.path.withCString { Darwin.rmdir($0) }
            return nil
        }
        return Entry(
            url: url,
            descriptor: descriptor,
            device: info.st_dev,
            inode: info.st_ino
        )
    }

    private static func release(_ entries: [Entry]) {
        for entry in entries.reversed() {
            if let current = fileInfo(at: entry.url),
               current.st_dev == entry.device,
               current.st_ino == entry.inode {
                _ = entry.url.path.withCString { Darwin.rmdir($0) }
            }
            Darwin.close(entry.descriptor)
        }
    }

    private static func fileInfo(at url: URL) -> stat? {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR
        else { return nil }
        return info
    }

    private static func modificationTime(of info: stat) -> TimeInterval {
        TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }
}
