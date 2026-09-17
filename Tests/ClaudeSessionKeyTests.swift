import Foundation
import XCTest

final class ClaudeSessionKeyTests: XCTestCase {
    /// A copy from the browser tends to come in as `sessionKey=...; other=...`.
    /// Saving it as-is would break the Cookie header, so only the value is extracted.
    func testNormalizationExtractsTheValueFromAPastedCookie() {
        let expected = String(repeating: "a", count: 40)

        XCTAssertEqual(ClaudeSessionKey.normalized(expected), expected)
        XCTAssertEqual(ClaudeSessionKey.normalized("  \(expected)\n"), expected)
        XCTAssertEqual(ClaudeSessionKey.normalized("sessionKey=\(expected)"), expected)
        XCTAssertEqual(
            ClaudeSessionKey.normalized("sessionKey=\(expected); lastActiveOrg=abc"),
            expected
        )
    }

    /// Since this value is spliced into a Cookie header, delimiter or control characters aren't allowed through.
    func testValidationRejectsValuesThatWouldBreakTheCookieHeader() {
        let valid = String(repeating: "b", count: 40)
        XCTAssertTrue(ClaudeSessionKey.isValid(valid))

        XCTAssertFalse(ClaudeSessionKey.isValid(""))
        XCTAssertFalse(ClaudeSessionKey.isValid("short"))
        XCTAssertFalse(ClaudeSessionKey.isValid("\(valid);injected=1"))
        XCTAssertFalse(ClaudeSessionKey.isValid("\(valid)=x"))
        XCTAssertFalse(ClaudeSessionKey.isValid("\(valid) with space"))
        XCTAssertFalse(ClaudeSessionKey.isValid("\(valid)\nSet-Cookie: evil=1"))
        XCTAssertFalse(ClaudeSessionKey.isValid(String(repeating: "c", count: 5_000)))
    }

    /// Since the organization ID is spliced into a URL, characters that could rewrite the path must not be allowed through.
    func testOrganizationIdentifierRejectsPathTraversal() {
        XCTAssertTrue(
            ClaudeWebUsageAPI.isSafeIdentifier("0b8c1e2f-3a4b-5c6d-7e8f-9a0b1c2d3e4f")
        )
        XCTAssertFalse(ClaudeWebUsageAPI.isSafeIdentifier("../../admin"))
        XCTAssertFalse(ClaudeWebUsageAPI.isSafeIdentifier("abc/usage?x=1"))
        XCTAssertFalse(ClaudeWebUsageAPI.isSafeIdentifier("abc def"))
        XCTAssertFalse(ClaudeWebUsageAPI.isSafeIdentifier("short"))
        XCTAssertFalse(ClaudeWebUsageAPI.isSafeIdentifier(String(repeating: "a", count: 65)))
    }
}
