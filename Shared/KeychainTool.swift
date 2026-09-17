import Foundation
import Security

/// Reads and writes a generic password item through `/usr/bin/security`.
///
/// Claude Code itself reads and writes through this same path, so the item's access settings
/// always keep `/usr/bin/security` (partition `apple-tool:`). Touching it directly through the
/// Security framework would swap the partition to the writer on every write, locking the other
/// side out and forcing it to prompt for the login password on every access. Using the same
/// tool means neither side locks the other out, whichever one writes.
enum KeychainTool {
    static let executable = URL(fileURLWithPath: "/usr/bin/security")

    /// If a permission dialog appears, this waits here for its response. No response is treated as a denial.
    static let timeout: TimeInterval = 60

    /// A single `security -i` line maxes out at about 4KB. A longer line gets cut off mid-way, and only
    /// the first part executes, saving a truncated value (observed empirically). Kept well under the limit rather than right at it.
    static let interactiveLineLimit = 4_000

    struct Invocation: Equatable {
        let arguments: [String]
        let standardInput: Data?
    }

    static func readInvocation(service: String, account: String) -> Invocation {
        Invocation(
            arguments: ["find-generic-password", "-a", account, "-s", service, "-w"],
            standardInput: nil
        )
    }

    /// Passes the value through standard input in interactive mode, keeping it off arguments visible to other processes.
    ///
    /// Only passed as an argument when it doesn't fit on one line (same as Claude Code). Arguments
    /// are visible only to processes of the same user, and those can already read the value through
    /// this same tool, so this doesn't widen what's exposed.
    static func writeInvocation(_ data: Data, service: String, account: String) -> Invocation {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        if isSafeInteractiveToken(account), isSafeInteractiveToken(service) {
            let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\""
            if line.utf8.count <= interactiveLineLimit {
                return Invocation(arguments: ["-i"], standardInput: Data((line + "\n").utf8))
            }
        }
        return Invocation(
            arguments: ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex],
            standardInput: nil
        )
    }

    /// Interactive-mode lines are delimited by double quotes, so characters that would break the delimiter aren't allowed through.
    private static func isSafeInteractiveToken(_ text: String) -> Bool {
        !text.isEmpty && !text.contains { "\"\\\n\r".contains($0) }
    }

    /// Reads. Returns the item's value on success.
    static func read(service: String, account: String) -> (OSStatus, Data?) {
        let (status, output) = run(readInvocation(service: service, account: account))
        guard status == errSecSuccess else { return (status, nil) }
        return (status, decodePasswordOutput(output))
    }

    static func write(_ data: Data, service: String, account: String) -> OSStatus {
        run(writeInvocation(data, service: service, account: account)).status
    }

    /// `-w`'s output. A value containing non-ASCII comes out hex-encoded (observed empirically).
    static func decodePasswordOutput(_ output: Data) -> Data {
        var trimmed = output
        while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
        if (try? JSONSerialization.jsonObject(with: trimmed)) != nil { return trimmed }
        if let decoded = decodeHex(trimmed) { return decoded }
        return trimmed
    }

    private static func decodeHex(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count / 2)
        var high: UInt8?
        for character in data {
            let nibble: UInt8
            switch character {
            case 0x30...0x39: nibble = character - 0x30
            case 0x41...0x46: nibble = character - 0x41 + 10
            case 0x61...0x66: nibble = character - 0x61 + 10
            default: return nil
            }
            if let upper = high {
                bytes.append(upper << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return Data(bytes)
    }

    /// The exit code is OSStatus's low 8 bits (item-not-found -25300 becomes 44).
    static func status(forExitCode code: Int32) -> OSStatus {
        guard code != 0 else { return errSecSuccess }
        let known: [OSStatus] = [
            errSecItemNotFound, errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled,
        ]
        return known.first { Int32(UInt32(bitPattern: $0) & 0xFF) == code } ?? errSecNotAvailable
    }

    /// Prevents the whole app from being killed by a write right after the other end exits.
    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    private static func run(_ invocation: Invocation) -> (status: OSStatus, output: Data) {
        _ = ignoreBrokenPipe
        let process = Process()
        process.executableURL = executable
        process.arguments = invocation.arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let input = invocation.standardInput.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice

        do { try process.run() } catch { return (errSecNotAvailable, Data()) }

        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        if let input, let data = invocation.standardInput {
            try? input.fileHandleForWriting.write(contentsOf: data)
            try? input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Closing a dialog that got no response is also treated as a denial, and never auto-retried.
        if timedOut.isSet { return (errSecInteractionNotAllowed, Data()) }
        return (status(forExitCode: process.terminationStatus), data)
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
