import Foundation
import XCTest

final class CodexAppServerTests: XCTestCase {
    /// The shape `codex app-server` actually returns. Key spelling differs from the log side.
    private let liveResponse = """
    {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,\
    "primary":{"usedPercent":36,"windowDurationMins":10080,"resetsAt":1789435319},\
    "secondary":null,"planType":"pro"},\
    "rateLimitsByLimitId":{\
    "codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark",\
    "primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1788921729},\
    "secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1789508529},\
    "planType":"pro"},\
    "codex":{"limitId":"codex","limitName":null,\
    "primary":{"usedPercent":36,"windowDurationMins":10080,"resetsAt":1789435319},\
    "secondary":null,"planType":"pro"}},\
    "accountId":"redacted"}}
    """

    private func buckets(_ line: String) -> [CodexCollector.RateLimits]? {
        CodexAppServer.buckets(fromResponseLine: Data(line.utf8))
    }

    func testReadsEveryBucketFromTheLiveShape() throws {
        let buckets = try XCTUnwrap(buckets(liveResponse))
        XCTAssertEqual(Set(buckets.compactMap(\.limit_id)), ["codex", "codex_bengalfox"])

        let plan = try XCTUnwrap(buckets.first { $0.limit_id == "codex" })
        XCTAssertEqual(plan.primary?.used_percent, 36)
        XCTAssertEqual(plan.primary?.window_minutes, 10_080)
        XCTAssertEqual(plan.plan_type, "pro")
        // The Pro plan window has no 5h. Confirms null is passed through as null instead of being dropped.
        XCTAssertNil(plan.secondary)

        let model = try XCTUnwrap(buckets.first { $0.limit_id == "codex_bengalfox" })
        XCTAssertEqual(model.limit_name, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(model.secondary?.window_minutes, 10_080)
    }

    /// If the plan window is weekly-only, the windows shown should be weekly-only too. A nonexistent 5h must not be synthesized.
    func testPlanBucketYieldsOnlyTheWeeklyWindow() throws {
        let buckets = try XCTUnwrap(buckets(liveResponse))
        let observations = buckets.map {
            CodexCollector.Observation(limits: $0, observedAt: Date())
        }
        let hit = try XCTUnwrap(CodexCollector.selectBucket(from: observations))
        XCTAssertEqual(hit.limits.limit_id, "codex")

        let windows = CodexCollector.usableWindows(of: hit.limits)
        XCTAssertEqual(windows.map(\.label), ["7d"])
        XCTAssertEqual(windows.first?.usedPercent, 36)
    }

    func testSkipsLinesThatAreNotTheAnsweredRequest() {
        XCTAssertNil(buckets(#"{"method":"remoteControl/status/changed","params":{}}"#))
        XCTAssertNil(buckets(#"{"id":1,"result":{"codexHome":"/Users/x/.codex"}}"#))
        XCTAssertNil(buckets("not json"))
    }

    /// Something like an expired auth comes back as an error. Returns empty and defers to the next executable.
    func testErrorResponseYieldsNoBuckets() {
        XCTAssertEqual(
            buckets(#"{"error":{"code":-32600,"message":"Not initialized"},"id":2}"#)?.count,
            0
        )
    }

    func testLocatorRejectsCommandsThatDoNotExist() {
        XCTAssertNil(CLILocator.locate("ai-usage-command-that-does-not-exist"))
    }

    /// Separately from the buckets, `account/rateLimits/read` returns a reset-credits summary
    /// at the top level of the response (the shape confirmed via `codex app-server generate-json-schema`).
    func testReadsResetCreditsAlongsideBuckets() throws {
        let response = """
        {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,\
        "primary":{"usedPercent":36,"windowDurationMins":10080,"resetsAt":1789435319},\
        "secondary":null,"planType":"pro"},\
        "rateLimitResetCredits":{"availableCount":2,"credits":[]}}}
        """
        XCTAssertEqual(
            CodexAppServer.resetCreditsAvailable(fromResponseLine: Data(response.utf8)), 2
        )
        // Reading the buckets is unaffected even when resetCredits is also present.
        XCTAssertEqual(buckets(response)?.first?.limit_id, "codex")
    }

    /// An older Codex doesn't return this field yet. Treated as nil when absent.
    func testResetCreditsIsNilWhenAbsent() {
        XCTAssertNil(CodexAppServer.resetCreditsAvailable(fromResponseLine: Data(liveResponse.utf8)))
    }
}
