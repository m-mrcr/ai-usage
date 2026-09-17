import Foundation
import Security
import XCTest

final class KeychainToolTests: XCTestCase {
    private let service = "Claude Code-credentials"

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// A normal-sized value is passed through interactive mode, and never ends up in an argument visible to other processes.
    func testShortPayloadGoesThroughStandardInput() throws {
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"fixture"}}"#.utf8)
        let invocation = KeychainTool.writeInvocation(payload, service: service, account: "fixture-user")

        XCTAssertEqual(invocation.arguments, ["-i"])
        XCTAssertFalse(invocation.arguments.joined().contains(hex(payload)))
        let line = try XCTUnwrap(invocation.standardInput.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(
            line,
            "add-generic-password -U -a \"fixture-user\" -s \"Claude Code-credentials\" -X \"\(hex(payload))\"\n"
        )
    }

    /// Passing a line over the single-line limit into interactive mode would overwrite the credential with a truncated value.
    /// A real item can exceed 5KB once it includes an MCP token.
    func testPayloadThatWouldOverflowTheInteractiveLineNeverUsesIt() {
        for size in [1_900, 1_990, 2_000, 5_300, 20_000] {
            let payload = Data(repeating: 0x61, count: size)
            let invocation = KeychainTool.writeInvocation(payload, service: service, account: "fixture-user")
            if let input = invocation.standardInput {
                XCTAssertLessThanOrEqual(input.count - 1, KeychainTool.interactiveLineLimit, "size \(size)")
            } else {
                XCTAssertEqual(
                    invocation.arguments,
                    ["add-generic-password", "-U", "-a", "fixture-user", "-s", service, "-X", hex(payload)]
                )
            }
        }
        XCTAssertNil(
            KeychainTool.writeInvocation(Data(repeating: 0x61, count: 5_300),
                                         service: service, account: "fixture-user").standardInput
        )
    }

    /// A name containing a quote would break the interactive-mode line, so it isn't used.
    func testAccountThatWouldBreakTheInteractiveLineFallsBackToArguments() {
        let invocation = KeychainTool.writeInvocation(Data("{}".utf8), service: service, account: "a\"b")
        XCTAssertNil(invocation.standardInput)
        XCTAssertEqual(invocation.arguments[3], "a\"b")
    }

    func testExitCodesMapToTheStatusesTheCallersBranchOn() {
        XCTAssertEqual(KeychainTool.status(forExitCode: 0), errSecSuccess)
        XCTAssertEqual(KeychainTool.status(forExitCode: 44), errSecItemNotFound)
        XCTAssertEqual(KeychainTool.status(forExitCode: 51), errSecAuthFailed)
        XCTAssertEqual(KeychainTool.status(forExitCode: 36), errSecInteractionNotAllowed)
        XCTAssertEqual(KeychainTool.status(forExitCode: 128), errSecUserCanceled)
        XCTAssertEqual(KeychainTool.status(forExitCode: 1), errSecNotAvailable)
    }

    func testPasswordOutputIsReadAsTextOrHex() {
        let json = Data(#"{"claudeAiOauth":{"accessToken":"fixture"}}"#.utf8)
        XCTAssertEqual(KeychainTool.decodePasswordOutput(json + Data("\n".utf8)), json)

        // A value containing non-ASCII is output as hex.
        let nonASCII = Data(#"{"mcpOAuth":{"名前":"値"}}"#.utf8)
        XCTAssertEqual(KeychainTool.decodePasswordOutput(Data((hex(nonASCII) + "\n").utf8)), nonASCII)

        // If it's neither, return it as-is and leave judging its shape to the caller.
        XCTAssertEqual(KeychainTool.decodePasswordOutput(Data("not json\n".utf8)), Data("not json".utf8))
    }
}
