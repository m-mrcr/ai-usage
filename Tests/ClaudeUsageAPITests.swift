import Foundation
import XCTest

final class ClaudeUsageAPIExtraUsageTests: XCTestCase {
    private func payload(
        isEnabled: Bool? = true,
        used: Double?,
        limit: Double?,
        decimalPlaces: Int? = 2
    ) -> ClaudeUsageAPI.ExtraUsagePayload {
        let json: [String: Any?] = [
            "is_enabled": isEnabled,
            "used_credits": used,
            "monthly_limit": limit,
            "decimal_places": decimalPlaces,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
        return try! JSONDecoder().decode(ClaudeUsageAPI.ExtraUsagePayload.self, from: data)
    }

    /// Matches a real `/api/oauth/usage` response: used_credits/monthly_limit are minor units
    /// scaled by decimal_places (516 at 2 places is $5.16).
    func testValidatedScalesByDecimalPlaces() throws {
        let snapshot = try XCTUnwrap(
            ClaudeUsageAPI.validatedExtraUsage(from: payload(used: 516, limit: 2_000))
        )
        XCTAssertEqual(snapshot.used, 5.16, accuracy: 0.001)
        XCTAssertEqual(snapshot.limit, 20, accuracy: 0.001)
    }

    func testValidatedRejectsWhenNotEnabled() {
        XCTAssertNil(
            ClaudeUsageAPI.validatedExtraUsage(from: payload(isEnabled: false, used: 516, limit: 2_000))
        )
    }

    /// A limit of 0 or less is treated as "not enabled", so $0/$0 is never shown.
    func testValidatedRejectsAZeroOrMissingLimit() {
        XCTAssertNil(ClaudeUsageAPI.validatedExtraUsage(from: payload(used: 0, limit: 0)))
        XCTAssertNil(ClaudeUsageAPI.validatedExtraUsage(from: payload(used: nil, limit: nil)))
        XCTAssertNil(ClaudeUsageAPI.validatedExtraUsage(from: payload(used: 500, limit: nil)))
        XCTAssertNil(ClaudeUsageAPI.validatedExtraUsage(from: nil))
    }

    func testValidatedRejectsNegativeUsed() {
        XCTAssertNil(ClaudeUsageAPI.validatedExtraUsage(from: payload(used: -100, limit: 2_000)))
    }

    /// Never trusts an overflowing response as-is. Caps it at a sensible multiple of the limit.
    func testValidatedClampsAnImplausiblyLargeUsedValue() throws {
        let snapshot = try XCTUnwrap(
            ClaudeUsageAPI.validatedExtraUsage(from: payload(used: 99_999_900, limit: 2_000))
        )
        XCTAssertEqual(snapshot.used, 200, accuracy: 0.001)
    }
}
