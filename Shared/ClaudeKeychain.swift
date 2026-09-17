import Foundation
import Security

/// Reads the OAuth token Claude Code stores in Keychain.
///
/// What's read is the user's own token, and it's only ever sent to Anthropic's usage endpoint.
/// An entry point for doing the same thing as Claude Code's `/usage` from this app.
/// Reads and writes go through `/usr/bin/security`, same as Claude Code (see `KeychainTool` for why).
enum ClaudeKeychain {
    struct OAuthCredential: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let scopes: [String]
        let subscriptionType: String?
        let clientID: String?
    }

    enum ReadFailure: Sendable {
        case notFound
        case accessDenied
        case malformed
        case expired
        /// The item exists but has no `claudeAiOauth`. Using only the desktop Claude app
        /// writes only `mcpOAuth` into the same item, producing this state.
        case notLinked
    }

    enum CredentialState: Sendable {
        case valid(OAuthCredential)
        case refreshable(OAuthCredential)
        case unavailable(ReadFailure)
    }

    enum SaveResult: Sendable {
        case saved
        case changed(CredentialState)
        case failed
    }

    private struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double?
            let scopes: [String]?
            let subscriptionType: String?
            let clientId: String?
        }
        let claudeAiOauth: OAuth?
    }

    private struct KeychainItem {
        let data: Data
    }

    /// The kind of content inside the Keychain item.
    ///
    /// The terminal CLI (`claudeAiOauth`) and the desktop app's MCP OAuth (`mcpOAuth`)
    /// share the same item, so confusing "it's broken" with "the CLI hasn't written yet"
    /// would give misleading guidance. Distinguish them here before reading.
    enum PayloadShape: Sendable, Equatable {
        case usable
        case notLinked
        case malformed
    }

    static func payloadShape(_ data: Data) -> PayloadShape {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .malformed }
        guard let oauth = root["claudeAiOauth"] else { return .notLinked }
        return oauth is [String: Any] ? .usable : .malformed
    }

    /// If `~/.claude.json` has `oauthAccount`, the user is signed in to Claude somewhere.
    /// Used to distinguish whether the missing CLI token means "not signed in" or "the CLI
    /// has never been used", so guidance can be steered toward a terminal sign-in.
    static func hasSignedInAccount() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = readBoundedFile(at: url, maximumBytes: accountFileMaximumBytes),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return root["oauthAccount"] is [String: Any]
    }

    /// Whether the terminal CLI is installed.
    ///
    /// If the CLI is present, leave refreshing the token to it and only read here.
    /// The refresh token rotates on every refresh, so if two places refresh it,
    /// one of them can end up holding a stale, unusable token.
    /// The binary bundled inside the desktop app doesn't count.
    static func terminalCLIInstalled() -> Bool {
        let manager = FileManager.default
        return terminalCLISearchPaths().contains {
            manager.isExecutableFile(atPath: $0.appendingPathComponent("claude").path)
        }
    }

    /// Directories to search for `claude`.
    /// An npm global install can land under nvm/fnm, so fixed paths alone aren't enough.
    static func terminalCLISearchPaths() -> [URL] {
        CLILocator.searchPaths()
    }

    /// The subscription plan name (e.g. "max"). Some versions don't have it, so it's treated as optional.
    static func subscriptionType() -> String? {
        switch credentialState() {
        case let .valid(credential), let .refreshable(credential):
            return credential.subscriptionType
        case .unavailable:
            return nil
        }
    }

    static func accessToken() -> String? {
        credential()?.accessToken
    }

    /// A compatibility API that only returns a valid access token.
    static func credential() -> OAuthCredential? {
        guard case let .valid(credential) = credentialState() else { return nil }
        return credential
    }

    /// Distinguishes a Keychain read failure from a refreshable expiration.
    /// As with Claude Code, becomes refresh-eligible starting 5 minutes before expiry.
    static func credentialState(
        now: Date = Date(), refreshSkew: TimeInterval = 5 * 60
    ) -> CredentialState {
        let (status, item) = readRawItem()
        guard status == errSecSuccess, let item else {
            switch status {
            case errSecItemNotFound:
                return .unavailable(.notFound)
            case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
                return .unavailable(.accessDenied)
            default:
                return .unavailable(.malformed)
            }
        }

        switch payloadShape(item.data) {
        case .malformed: return .unavailable(.malformed)
        case .notLinked: return .unavailable(.notLinked)
        case .usable: break
        }

        guard let oauth = try? JSONDecoder().decode(Credentials.self, from: item.data).claudeAiOauth,
              let credential = validatedCredential(oauth)
        else { return .unavailable(.malformed) }

        if let expiresAt = credential.expiresAt,
           expiresAt <= now.addingTimeInterval(max(0, refreshSkew)) {
            return credential.refreshToken == nil
                ? .unavailable(.expired)
                : .refreshable(credential)
        }
        return .valid(credential)
    }

    /// Before rotating the refresh token, confirm it's safe to write back to the same Keychain item.
    /// This just writes back the same data, so on failure, never start the OAuth refresh.
    static func prepareForRefresh(_ expected: OAuthCredential) -> Bool {
        let (status, item) = readRawItem()
        guard status == errSecSuccess, let item,
              rawCredentialMatches(item.data, expected: expected)
        else { return false }

        return writeRawItem(item.data) == errSecSuccess
    }

    /// Since Claude Code's refresh token rotates, only write back to Keychain — preserving unknown
    /// fields — when both the access and refresh tokens still match what was read. On conflict, defer to the newer sibling write.
    static func saveRefreshedCredential(
        expected: OAuthCredential,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        scopes: [String]? = nil
    ) -> SaveResult {
        for attempt in 0..<3 {
            let (status, item) = readRawItem()
            guard status == errSecSuccess else {
                if attempt < 2, shouldRetryReadFailure(status) {
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
                return .failed
            }
            guard let item else { return .failed }

            guard rawCredentialMatches(item.data, expected: expected) else {
                return .changed(credentialState())
            }
            guard let updated = updatedCredentialData(
                item.data,
                expectedAccessToken: expected.accessToken,
                expectedRefreshToken: expected.refreshToken,
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                scopes: scopes
            ) else { return .failed }

            let updateStatus = writeRawItem(updated)
            if updateStatus == errSecSuccess { return .saved }
            if [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled]
                .contains(updateStatus) {
                return .failed
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
        }
        return .failed
    }

    /// Don't retry on an explicit denial/cancellation or a deleted item, to avoid a string of repeated confirmation dialogs.
    static func shouldRetryReadFailure(_ status: OSStatus) -> Bool {
        ![
            errSecItemNotFound,
            errSecAuthFailed,
            errSecInteractionNotAllowed,
            errSecUserCanceled,
        ].contains(status)
    }

    /// The pure part of the JSON merge. Never drops Keychain's sibling keys or future fields.
    static func updatedCredentialData(
        _ data: Data,
        expectedAccessToken: String,
        expectedRefreshToken: String?,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        scopes: [String]? = nil
    ) -> Data? {
        guard isSafeToken(accessToken), isSafeToken(refreshToken),
              expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > Date(timeIntervalSince1970: 0),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              oauth["accessToken"] as? String == expectedAccessToken,
              oauth["refreshToken"] as? String == expectedRefreshToken
        else { return nil }

        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1_000
        if let scopes {
            oauth["scopes"] = scopes
        }
        root["claudeAiOauth"] = oauth
        guard JSONSerialization.isValidJSONObject(root) else { return nil }
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func rawCredentialMatches(
        _ data: Data, expected: OAuthCredential
    ) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any]
        else { return false }
        return oauth["accessToken"] as? String == expected.accessToken
            && oauth["refreshToken"] as? String == expected.refreshToken
            && oauth["clientId"] as? String == expected.clientID
    }

    private static func validatedCredential(_ oauth: Credentials.OAuth) -> OAuthCredential? {
        guard isSafeToken(oauth.accessToken) else { return nil }

        let refreshToken: String?
        if let raw = oauth.refreshToken {
            guard isSafeToken(raw) else { return nil }
            refreshToken = raw
        } else {
            refreshToken = nil
        }

        let expiresAt: Date?
        if let raw = oauth.expiresAt {
            guard raw.isFinite else { return nil }
            let parsed = Date(timeIntervalSince1970: raw / 1_000)
            guard parsed.timeIntervalSince1970.isFinite else { return nil }
            expiresAt = parsed
        } else {
            expiresAt = nil
        }

        let scopes = (oauth.scopes ?? []).compactMap(sanitizedMetadata)
        let subscription = oauth.subscriptionType.flatMap(sanitizedMetadata)
        let clientID: String?
        if let raw = oauth.clientId {
            guard isSafeClientID(raw) else { return nil }
            clientID = raw
        } else {
            clientID = nil
        }
        return OAuthCredential(
            accessToken: oauth.accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: scopes,
            subscriptionType: subscription,
            clientID: clientID
        )
    }

    static let service = "Claude Code-credentials"

    private static func readRawItem() -> (OSStatus, KeychainItem?) {
        let (status, data) = KeychainTool.read(service: service, account: NSUserName())
        guard status == errSecSuccess, let data else { return (status, nil) }
        return (status, KeychainItem(data: data))
    }

    /// Overwrites with `add-generic-password -U`, same as Claude Code.
    /// Pinning the item to one via service and macOS username also matches Claude Code.
    private static func writeRawItem(_ data: Data) -> OSStatus {
        KeychainTool.write(data, service: service, account: NSUserName())
    }

    /// For the User-Agent. Without `claude-code/<version>` it falls into a strict 429 bucket,
    /// so this transcribes the actual version of Claude Code running on this machine.
    static func installedVersion() -> String {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: projects, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return fallbackVersion }

        var newest: (url: URL, modified: Date)?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || modified > newest!.modified { newest = (url, modified) }
        }

        guard let file = newest?.url,
              let data = readTail(of: file, maximumBytes: versionTailBytes)
        else { return fallbackVersion }

        for rawLine in data.split(separator: 0x0A).reversed().prefix(100) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                  let version = object["version"] as? String,
                  isSafeVersion(version)
            else { continue }
            return version
        }
        return fallbackVersion
    }

    /// Reads from the start up to a byte limit. Files exceeding the limit are not handled.
    private static func readBoundedFile(at url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes >= 0, maximumBytes < Int.max,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes
        else { return nil }
        return data
    }

    /// Even if the offset lands mid-UTF-8, discards the first incomplete line and returns from a line boundary.
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

    private static func isSafeVersion(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                return true
            case 0x2B, 0x2D, 0x2E, 0x5F: // + - . _
                return true
            default:
                return false
            }
        }
    }

    private static func isSafeToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 16_384 else { return false }
        return value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    private static func isSafeClientID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    private static func sanitizedMetadata(_ value: String) -> String? {
        let scalars = value.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(128))
    }

    private static let versionTailBytes = 256 * 1_024
    private static let accountFileMaximumBytes = 4 * 1_024 * 1_024
    private static let fallbackVersion = "2.1.221"
}
