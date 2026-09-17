import Foundation
import XCTest

final class ClaudeExtraUsageAPITests: XCTestCase {
    private func payload(used: Double?, limit: Double?) -> ClaudeExtraUsageAPI.Payload {
        let json: [String: Any?] = ["used_credits": used, "monthly_limit": limit]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
        return try! JSONDecoder().decode(ClaudeExtraUsageAPI.Payload.self, from: data)
    }

    func testValidatedAcceptsAPlausibleUsedAndLimit() throws {
        let snapshot = try XCTUnwrap(
            ClaudeExtraUsageAPI.validated(payload(used: 5.16, limit: 20))
        )
        XCTAssertEqual(snapshot.used, 5.16, accuracy: 0.001)
        XCTAssertEqual(snapshot.limit, 20, accuracy: 0.001)
    }

    /// A limit of 0 or less is treated as "not enabled", so $0/$0 is never shown.
    func testValidatedRejectsAZeroOrMissingLimit() {
        XCTAssertNil(ClaudeExtraUsageAPI.validated(payload(used: 0, limit: 0)))
        XCTAssertNil(ClaudeExtraUsageAPI.validated(payload(used: nil, limit: nil)))
        XCTAssertNil(ClaudeExtraUsageAPI.validated(payload(used: 5, limit: nil)))
    }

    func testValidatedRejectsNegativeUsed() {
        XCTAssertNil(ClaudeExtraUsageAPI.validated(payload(used: -1, limit: 20)))
    }

    /// Never trusts an overflowing response as-is. Caps it at a sensible multiple of the limit.
    func testValidatedClampsAnImplausiblyLargeUsedValue() throws {
        let snapshot = try XCTUnwrap(
            ClaudeExtraUsageAPI.validated(payload(used: 999_999, limit: 20))
        )
        XCTAssertEqual(snapshot.used, 200, accuracy: 0.001)
    }
}
