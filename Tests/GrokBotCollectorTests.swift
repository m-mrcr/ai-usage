import Foundation
import XCTest

final class GrokBotCollectorTests: XCTestCase {
    /// Grok Bot and Cursor run on the same account, so one stored session is enough for both.
    func testBothRoutesShareOneStoredSession() {
        XCTAssertEqual(CursorSession.service, "jp.co.forestx.aiusage.grokbot-session")
    }

    private func status(_ raw: [String: Any]) throws -> GrokBotCollector.Status {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(GrokBotCollector.Status.self, from: data)
    }

    /// Passes a real response through as-is, locking in that it assembles into the value shown on screen.
    func testUsageStatusBecomesAWindowWithItsResetAndPlan() throws {
        let agent = GrokBotCollector.agent(from: try status([
            "currentPeriodStart": "2026-09-05T18:22:04.315Z",
            "nextResetTimestampUtc": "2026-09-09T07:05:17.861Z",
            "usagePercent": 2.142593,
            "hasAvailableUsage": true,
            "hasNonZeroIncludedLimit": true,
            "grokPlanLabel": "X Premium+",
        ]))

        XCTAssertEqual(agent.id, "grok-bot")
        XCTAssertEqual(agent.plan, "X Premium+")
        XCTAssertEqual(agent.status, .ok)

        let window = try XCTUnwrap(agent.windows.first)
        XCTAssertEqual(window.usedPercent, 2.142593, accuracy: 0.0001)
        XCTAssertEqual(window.label, "Period")
        XCTAssertEqual(
            window.resetsAt,
            ISO8601DateFormatter.parsing.date(from: "2026-09-09T07:05:17.861Z")
        )
    }

    /// A percentage is meaningless for a plan with no included limit. Showing a 0% bar would misleadingly suggest plenty of room.
    func testNoIncludedLimitProducesNoWindow() throws {
        let agent = GrokBotCollector.agent(from: try status([
            "usagePercent": 0,
            "hasNonZeroIncludedLimit": false,
            "grokPlanLabel": "X Premium+",
        ]))

        XCTAssertTrue(agent.windows.isEmpty)
        XCTAssertEqual(agent.status, .unavailable)
    }

    func testMissingPercentProducesNoWindow() throws {
        let agent = GrokBotCollector.agent(from: try status(["grokPlanLabel": "X Premium+"]))
        XCTAssertTrue(agent.windows.isEmpty)
        XCTAssertEqual(agent.status, .unavailable)
    }

    /// For double-submit-style CSRF protection. Carries the same value as the cookie in a header too.
    func testCSRFTokenIsTakenFromTheCookie() {
        XCTAssertEqual(
            CursorAPI.csrfToken(in: "a=1; csrf-token=tok123; b=2"),
            "tok123"
        )
        XCTAssertNil(CursorAPI.csrfToken(in: "a=1; b=2"))
        XCTAssertNil(CursorAPI.csrfToken(in: "csrf-token="))
    }

    /// Since this value is spliced into a Cookie header, letting a newline through would split the header.
    func testSessionValidationRejectsHeaderBreakingValues() {
        let valid = "WorkosCursorSessionToken=abc123; workos_id=xyz"
        XCTAssertTrue(CursorSession.isValid(valid))
        XCTAssertEqual(CursorSession.normalized("  a=1 ;; b=2 ; junk ; "), "a=1; b=2")

        XCTAssertFalse(CursorSession.isValid(""))
        XCTAssertFalse(CursorSession.isValid("nocookievalue"))
        XCTAssertFalse(CursorSession.isValid("a=1\nSet-Cookie: evil=1"))
        XCTAssertFalse(CursorSession.isValid(String(repeating: "a=1; ", count: 3_000)))
    }
}

private extension ISO8601DateFormatter {
    static var parsing: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
