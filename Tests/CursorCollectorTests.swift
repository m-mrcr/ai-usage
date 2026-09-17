import Foundation
import XCTest

final class CursorCollectorTests: XCTestCase {
    private func usage(_ raw: [String: Any]) throws -> CursorCollector.Usage {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(CursorCollector.Usage.self, from: data)
    }

    /// Passes a real response through as-is, locking in that it assembles into the value shown on screen.
    func testPlanUsageBecomesAPeriodWindow() throws {
        let agent = CursorCollector.agent(from: try usage([
            "billingCycleStart": "1788332436608",
            "billingCycleEnd": "1790924436608",
            "planUsage": ["totalPercentUsed": 42, "autoPercentUsed": 10, "apiPercentUsed": 5],
        ]))

        XCTAssertEqual(agent.id, "cursor")
        XCTAssertEqual(agent.status, .ok)

        let window = try XCTUnwrap(agent.windows.first)
        XCTAssertEqual(window.usedPercent, 42, accuracy: 0.0001)
        XCTAssertEqual(window.label, "Period")
        XCTAssertEqual(window.resetsAt, Date(timeIntervalSince1970: 1_790_924_436.608))
    }

    func testMissingPlanUsageProducesNoWindow() throws {
        let agent = CursorCollector.agent(from: try usage(["billingCycleEnd": "1790924436608"]))
        XCTAssertTrue(agent.windows.isEmpty)
        XCTAssertEqual(agent.status, .unavailable)
    }

    /// Reading milliseconds as seconds lands on a date tens of thousands of years out. Rejects the digit mix-up.
    func testEpochMillisecondsAreRejectedWhenOutOfRange() {
        XCTAssertEqual(
            CursorAPI.parseEpochMilliseconds("1790924436608"),
            Date(timeIntervalSince1970: 1_790_924_436.608)
        )
        XCTAssertNil(CursorAPI.parseEpochMilliseconds("1790924436608000"))
        XCTAssertNil(CursorAPI.parseEpochMilliseconds("not-a-number"))
        XCTAssertNil(CursorAPI.parseEpochMilliseconds(nil))
    }
}
