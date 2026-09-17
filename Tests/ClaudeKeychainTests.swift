import Foundation
import Security
import XCTest

final class ClaudeKeychainTests: XCTestCase {
    func testReadPinsTheClaudeServiceAndMacAccount() {
        let invocation = KeychainTool.readInvocation(
            service: ClaudeKeychain.service, account: "fixture-user"
        )
        XCTAssertEqual(
            invocation.arguments,
            ["find-generic-password", "-a", "fixture-user", "-s", "Claude Code-credentials", "-w"]
        )
        XCTAssertNil(invocation.standardInput)
    }

    func testKeychainCancellationAndAccessDenialAreNotRetried() {
        XCTAssertFalse(ClaudeKeychain.shouldRetryReadFailure(errSecItemNotFound))
        XCTAssertFalse(ClaudeKeychain.shouldRetryReadFailure(errSecAuthFailed))
        XCTAssertFalse(ClaudeKeychain.shouldRetryReadFailure(errSecInteractionNotAllowed))
        XCTAssertFalse(ClaudeKeychain.shouldRetryReadFailure(errSecUserCanceled))
        XCTAssertTrue(ClaudeKeychain.shouldRetryReadFailure(errSecNotAvailable))
    }

    func testPayloadShapeSeparatesAnMcpOnlyItemFromMalformedData() throws {
        // Using only the desktop Claude app leaves only mcpOAuth in the same Keychain item.
        // Treating this the same as malformed would give "sign in again" guidance, when what's
        // actually needed is a terminal sign-in — and the user would never get there.
        let mcpOnly = try JSONSerialization.data(
            withJSONObject: ["mcpOAuth": ["server": ["accessToken": "value"]]]
        )
        XCTAssertEqual(ClaudeKeychain.payloadShape(mcpOnly), .notLinked)

        let linked = try JSONSerialization.data(
            withJSONObject: [
                "claudeAiOauth": ["accessToken": "value"],
                "mcpOAuth": ["server": ["accessToken": "value"]],
            ]
        )
        XCTAssertEqual(ClaudeKeychain.payloadShape(linked), .usable)

        XCTAssertEqual(ClaudeKeychain.payloadShape(Data("not json".utf8)), .malformed)

        let wrongType = try JSONSerialization.data(
            withJSONObject: ["claudeAiOauth": "unexpected"]
        )
        XCTAssertEqual(ClaudeKeychain.payloadShape(wrongType), .malformed)
    }

    /// While the CLI is present, token refresh is left to it (since the refresh token rotates,
    /// refreshing from two places could leave one holding a stale token). The binary bundled
    /// inside the desktop app never acts as the refresher, so mistaking it for the CLI would leave no refresher at all.
    func testTerminalCLIDetectionIgnoresTheDesktopBundledBinary() {
        let bundledRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude").path

        XCTAssertFalse(
            ClaudeKeychain.terminalCLISearchPaths().contains { $0.path.hasPrefix(bundledRoot) },
            "The desktop app's bundled binary must not be included in the search targets"
        )
    }

    /// An npm global install can land under nvm/fnm, and fixed paths alone would miss it.
    /// Missing it would misjudge "the CLI isn't present" and write back, locking the CLI out.
    func testTerminalCLIDetectionCoversVersionManagerLayouts() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = ClaudeKeychain.terminalCLISearchPaths().map(\.path)

        for fixed in ["/opt/homebrew/bin", "/usr/local/bin"] {
            XCTAssertTrue(paths.contains(fixed), "\(fixed) should be included in the search targets")
        }

        let nvmRoot = home.appendingPathComponent(".nvm/versions/node")
        let nvmVersions = (try? FileManager.default.contentsOfDirectory(
            at: nvmRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for version in nvmVersions.prefix(64) {
            XCTAssertTrue(
                paths.contains(version.appendingPathComponent("bin").path),
                "\(version.lastPathComponent) under nvm should be included in the search targets"
            )
        }

        let expected = ClaudeKeychain.terminalCLISearchPaths().contains {
            FileManager.default.isExecutableFile(
                atPath: $0.appendingPathComponent("claude").path
            )
        }
        XCTAssertEqual(ClaudeKeychain.terminalCLIInstalled(), expected)
    }

    func testCredentialMergeRotatesTokensAndPreservesUnknownFields() throws {
        let source: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "old-access",
                "refreshToken": "old-refresh",
                "expiresAt": 1_700_000_000_000,
                "scopes": ["user:profile"],
                "subscriptionType": "pro",
                "clientId": "future-client",
                "futureField": ["enabled": true],
            ],
            "mcpOAuth": ["server": ["accessToken": "untouched"]],
            "futureRoot": "untouched",
        ]
        let data = try JSONSerialization.data(withJSONObject: source)
        let expiration = Date(timeIntervalSince1970: 1_800_000_000)

        let updated = try XCTUnwrap(ClaudeKeychain.updatedCredentialData(
            data,
            expectedAccessToken: "old-access",
            expectedRefreshToken: "old-refresh",
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresAt: expiration,
            scopes: ["user:profile", "user:inference"]
        ))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: updated) as? [String: Any]
        )
        let oauth = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])

        XCTAssertEqual(oauth["accessToken"] as? String, "new-access")
        XCTAssertEqual(oauth["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual(oauth["expiresAt"] as? Double, 1_800_000_000_000)
        XCTAssertEqual(
            oauth["scopes"] as? [String],
            ["user:profile", "user:inference"]
        )
        XCTAssertEqual(oauth["subscriptionType"] as? String, "pro")
        XCTAssertEqual(oauth["clientId"] as? String, "future-client")
        XCTAssertEqual(
            (oauth["futureField"] as? [String: Any])?["enabled"] as? Bool,
            true
        )
        XCTAssertEqual(root["futureRoot"] as? String, "untouched")
        let mcp = try XCTUnwrap(root["mcpOAuth"] as? [String: Any])
        let server = try XCTUnwrap(mcp["server"] as? [String: Any])
        XCTAssertEqual(server["accessToken"] as? String, "untouched")
    }

    func testCredentialMergeRejectsConcurrentTokenChange() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "newer-access",
                "refreshToken": "newer-refresh",
            ],
        ])

        XCTAssertNil(ClaudeKeychain.updatedCredentialData(
            data,
            expectedAccessToken: "old-access",
            expectedRefreshToken: "old-refresh",
            accessToken: "ours-access",
            refreshToken: "ours-refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
    }

    func testCredentialMergeSupportsPreviouslyMissingRefreshToken() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "old-access"],
            "sibling": 42,
        ])

        let updated = try XCTUnwrap(ClaudeKeychain.updatedCredentialData(
            data,
            expectedAccessToken: "old-access",
            expectedRefreshToken: nil,
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: updated) as? [String: Any]
        )
        XCTAssertEqual(root["sibling"] as? Int, 42)
    }
}
