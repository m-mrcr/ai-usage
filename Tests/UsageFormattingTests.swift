import Foundation
import XCTest

final class UsageFormattingTests: XCTestCase {
    func testResetCreditsSummaryTextCoversZeroOneAndMany() {
        XCTAssertEqual(
            ResetCredits(available: 0).summaryText(language: .english), "No resets"
        )
        XCTAssertEqual(
            ResetCredits(available: 1).summaryText(language: .english), "1 reset"
        )
        XCTAssertEqual(
            ResetCredits(available: 2).summaryText(language: .english), "2 resets"
        )
    }

    func testExtraUsageSummaryTextFormatsBothAmountsAsCurrency() {
        let text = ExtraUsage(used: 5.16, limit: 20).summaryText(language: .english)
        XCTAssertTrue(text.contains("5.16"))
        XCTAssertTrue(text.contains("20"))
        XCTAssertTrue(text.contains("/"))
    }

    /// So Codex and Claude can be compared side by side, only Claude shows an explicit off state even when not yet fetched.
    func testExtrasTextShowsExplicitOffStateOnlyForClaude() {
        let claudeWithoutExtraUsage = AgentUsage(
            id: "claude-code", name: "Claude Code", plan: nil, windows: [],
            observedAt: Date(), source: "test", status: .ok, note: nil
        )
        XCTAssertEqual(
            claudeWithoutExtraUsage.extrasText(language: .english), "Extra usage off"
        )

        let codexWithoutResetCredits = AgentUsage(
            id: "codex", name: "Codex", plan: nil, windows: [],
            observedAt: Date(), source: "test", status: .ok, note: nil
        )
        XCTAssertNil(codexWithoutResetCredits.extrasText(language: .english))
    }

    func testExtrasTextPrefersResetCreditsOverExtraUsageWhenBothArePresent() {
        // In practice both never land on the same agent, but this locks in that resetCredits takes priority.
        let agent = AgentUsage(
            id: "codex", name: "Codex", plan: nil, windows: [],
            observedAt: Date(), source: "test", status: .ok, note: nil,
            resetCredits: ResetCredits(available: 1),
            extraUsage: ExtraUsage(used: 1, limit: 2)
        )
        XCTAssertEqual(agent.extrasText(language: .english), "1 reset")
    }
}
