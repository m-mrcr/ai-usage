import Foundation
import XCTest

final class CodexCollectorTests: XCTestCase {
    func testFindRateLimitsSkipsNonObjectValues() {
        let invalidValues: [Any] = [
            NSNull(),
            "invalid",
            42,
            true,
            ["unexpected"],
            [String: Any](),
        ]

        for value in invalidValues {
            XCTAssertNil(
                CodexCollector.findRateLimits(in: ["rate_limits": value]),
                "Expected \(type(of: value)) to be ignored"
            )
        }
    }

    func testFindRateLimitsContinuesAfterNullValue() throws {
        let root: [String: Any] = [
            "rate_limits": NSNull(),
            "nested": [
                "rate_limits": [
                    "primary": [
                        "used_percent": 42.0,
                        "window_minutes": 10_080,
                    ],
                    "plan_type": "pro",
                ],
            ],
        ]

        let limits = try XCTUnwrap(CodexCollector.findRateLimits(in: root))
        XCTAssertEqual(try XCTUnwrap(limits.primary?.used_percent), 42.0, accuracy: 0.001)
        XCTAssertEqual(limits.primary?.window_minutes, 10_080)
        XCTAssertEqual(limits.plan_type, "pro")
    }

    private func limits(_ raw: [String: Any]) throws -> CodexCollector.RateLimits {
        try XCTUnwrap(CodexCollector.findRateLimits(in: ["rate_limits": raw]))
    }

    /// Codex writes plan windows and per-model windows into the same log. Taking whichever was
    /// written last would flip the display depending on which model was used most recently.
    /// The real log's `premium` bucket arrives with both primary/secondary null.
    /// Adopting this as a windowless bucket would leave the display empty.
    func testFindRateLimitsSkipsTheWindowlessBucket() {
        XCTAssertNil(CodexCollector.findRateLimits(in: ["rate_limits": [
            "limit_id": "premium",
            "limit_name": NSNull(),
            "primary": NSNull(),
            "secondary": NSNull(),
            "plan_type": "pro",
        ] as [String: Any]]))
    }

    func testSelectBucketPrefersThePlanLimitOverANewerModelLimit() throws {
        let plan = try limits([
            "limit_id": "codex",
            "plan_type": "pro",
            "primary": ["used_percent": 99, "window_minutes": 10_080],
        ])
        let model = try limits([
            "limit_id": "codex_bengalfox",
            "limit_name": "GPT-5.3-Codex-Spark",
            "plan_type": "pro",
            "primary": ["used_percent": 0, "window_minutes": 300],
            "secondary": ["used_percent": 0, "window_minutes": 10_080],
        ])
        // A windowless bucket is rejected by findRateLimits, so this pokes selectBucket's guard directly.
        let premium = CodexCollector.RateLimits(
            primary: nil, secondary: nil, plan_type: "pro",
            limit_id: "premium", limit_name: nil
        )

        let older = Date(timeIntervalSince1970: 1_788_666_200)
        let newer = Date(timeIntervalSince1970: 1_788_666_500)

        let picked = try XCTUnwrap(CodexCollector.selectBucket(from: [
            CodexCollector.Observation(limits: model, observedAt: newer),
            CodexCollector.Observation(limits: premium, observedAt: newer),
            CodexCollector.Observation(limits: plan, observedAt: older),
        ]))

        XCTAssertEqual(picked.limits.limit_id, "codex")
        XCTAssertTrue(picked.isPlanBucket)
        XCTAssertEqual(
            CodexCollector.usableWindows(of: picked.limits).map(\.id),
            ["primary-w10080"]
        )
    }

    /// Per-model windows are shown in the list too, but since they tend to sit at 0% unused, they're never used as the representative value.
    func testModelBucketsBecomeSupplementaryWindowsAndNeverLeadTheSummary() throws {
        let model = try limits([
            "limit_id": "codex_bengalfox",
            "limit_name": "GPT-5.3-Codex-Spark",
            "plan_type": "pro",
            "primary": ["used_percent": 0, "window_minutes": 300],
        ])
        let plan = try limits([
            "limit_id": "codex",
            "plan_type": "pro",
            "primary": ["used_percent": 99, "window_minutes": 10_080],
        ])

        let supplementary = CodexCollector.usableWindows(of: model, supplementary: true)
        XCTAssertEqual(supplementary.map(\.id), ["codex_bengalfox-primary-w300"])
        XCTAssertEqual(supplementary.map(\.label), ["Spark 5h"])
        XCTAssertTrue(supplementary.allSatisfy(\.isSupplementary))

        let agent = AgentUsage(
            id: "codex", name: "Codex", plan: "Pro",
            windows: CodexCollector.usableWindows(of: plan) + supplementary,
            observedAt: Date(), source: "session log", status: .ok, note: nil
        )

        // The 5-hour window is shorter, but showing a 0% supplementary window in the headline would misleadingly suggest plenty of room.
        XCTAssertEqual(agent.headlineWindow?.usedPercent, 99)
        XCTAssertEqual(agent.tightestWindow?.usedPercent, 99)
        // In the list, plan windows come first, supplementary ones come after.
        XCTAssertEqual(agent.displayWindows.map(\.isSupplementary), [false, true])
    }

    func testShortBucketNameFallsBackToTheLimitIDWhenUnnamed() throws {
        let unnamed = try limits([
            "limit_id": "codex_otter",
            "plan_type": "pro",
            "primary": ["used_percent": 5, "window_minutes": 300],
        ])
        XCTAssertEqual(CodexCollector.shortBucketName(of: unnamed), "otter")
        XCTAssertEqual(
            CodexCollector.usableWindows(of: unnamed, supplementary: true).map(\.label),
            ["otter 5h"]
        )
    }

    func testSelectBucketTreatsEntriesWithoutALimitIDAsThePlanBucket() throws {
        let legacy = try limits([
            "plan_type": "pro",
            "primary": ["used_percent": 42, "window_minutes": 10_080],
        ])
        let model = try limits([
            "limit_id": "codex_bengalfox",
            "plan_type": "pro",
            "primary": ["used_percent": 0, "window_minutes": 300],
        ])

        let picked = try XCTUnwrap(CodexCollector.selectBucket(from: [
            CodexCollector.Observation(
                limits: model, observedAt: Date(timeIntervalSince1970: 1_788_666_500)
            ),
            CodexCollector.Observation(
                limits: legacy, observedAt: Date(timeIntervalSince1970: 1_788_666_200)
            ),
        ]))

        XCTAssertNil(picked.limits.limit_id)
        XCTAssertTrue(picked.isPlanBucket)
    }

    func testSelectBucketSkipsBucketsWithoutUsableWindows() throws {
        let premium = CodexCollector.RateLimits(
            primary: nil, secondary: nil, plan_type: "pro",
            limit_id: "premium", limit_name: nil
        )

        XCTAssertNil(CodexCollector.selectBucket(from: [
            CodexCollector.Observation(
                limits: premium, observedAt: Date(timeIntervalSince1970: 1_788_666_500)
            ),
        ]))
    }

    /// An unused model's window stays at 0%, so showing it instead would misleadingly suggest plenty of room.
    /// No number is shown; instead it falls back to guidance indicating only per-model windows exist.
    func testModelOnlyLogsProduceNoNumbersButAreDistinguishable() throws {
        let model = try limits([
            "limit_id": "codex_bengalfox",
            "plan_type": "pro",
            "primary": ["used_percent": 0, "window_minutes": 300],
        ])
        let observations = [
            CodexCollector.Observation(
                limits: model, observedAt: Date(timeIntervalSince1970: 1_788_666_500)
            ),
        ]

        XCTAssertNil(CodexCollector.selectBucket(from: observations))
        XCTAssertTrue(CodexCollector.hasOnlyModelBuckets(observations))
        XCTAssertFalse(CodexCollector.hasOnlyModelBuckets([]))
    }

    func testScanTailKeepsTheNewestEntryForEachBucket() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func line(_ id: String, _ used: Int, _ minutes: Int, _ timestamp: String) -> String {
            #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","rate_limits":{"limit_id":"\#(id)","plan_type":"pro","primary":{"used_percent":\#(used),"window_minutes":\#(minutes)}}}}"#
        }

        let logURL = directory.appendingPathComponent("rollout-buckets.jsonl")
        try Data([
            line("codex", 90, 10_080, "2020-01-01T00:00:00Z"),
            line("codex", 99, 10_080, "2020-01-01T00:01:00Z"),
            line("codex_bengalfox", 0, 300, "2020-01-01T00:02:00Z"),
        ].joined(separator: "\n").utf8).write(to: logURL, options: .atomic)

        let hits = CodexCollector.scanTail(of: logURL)

        XCTAssertEqual(Set(hits.map { $0.limits.limit_id }), ["codex", "codex_bengalfox"])
        let plan = try XCTUnwrap(hits.first { $0.limits.limit_id == "codex" })
        XCTAssertEqual(try XCTUnwrap(plan.limits.primary?.used_percent), 99, accuracy: 0.001)
    }

    func testScanTailFallsBackPastMalformedAndInvalidLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let validLine = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":56,"window_minutes":10080},"plan_type":"pro"}}}"#
        let malformedLine = "{\"rate_limits\":"
        let invalidLiterals = [
            "null",
            "\"invalid\"",
            "42",
            "true",
            "[\"unexpected\"]",
            "{}",
        ]

        for (index, literal) in invalidLiterals.enumerated() {
            let logURL = directory.appendingPathComponent("rollout-test-\(index).jsonl")
            let invalidLine = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":\(literal)}}"
            try Data([validLine, invalidLine, malformedLine].joined(separator: "\n").utf8)
                .write(to: logURL, options: .atomic)

            let hit = try XCTUnwrap(
                CodexCollector.scanTail(of: logURL).first,
                "Expected fallback after \(literal)"
            )
            XCTAssertEqual(
                try XCTUnwrap(hit.limits.primary?.used_percent),
                56.0,
                accuracy: 0.001
            )
            XCTAssertEqual(hit.limits.primary?.window_minutes, 10_080)
            XCTAssertEqual(hit.limits.plan_type, "pro")
        }
    }
}
