import Foundation

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    /// stdout and stderr combined, in order.
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }

    public var succeeded: Bool { status == 0 }
}

/// Runs external commands. Production uses `ProcessRunner`; tests inject fakes.
public protocol CommandRunner: Sendable {
    /// `command` is looked up on PATH (or is an absolute path).
    func run(_ command: String, _ arguments: [String]) async -> CommandResult
}

public struct ProcessRunner: CommandRunner {
    /// Apps opened from Finder get only /usr/bin:/bin:/usr/sbin:/sbin; nginx and brew live in Homebrew.
    public static let defaultPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

    public let path: String
    public let environment: [String: String]

    public init(path: String = ProcessRunner.defaultPath, environment: [String: String] = [:]) {
        self.path = path
        self.environment = environment
    }

    public func run(_ command: String, _ arguments: [String]) async -> CommandResult {
        let path = self.path
        let extra = environment
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                // env resolves `command` against our PATH, not the app's minimal one
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [command] + arguments
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = path
                env.merge(extra) { _, new in new }
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice  // never hang on a prompt
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CommandResult(status: -1, output: "\(error.localizedDescription)"))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: CommandResult(status: process.terminationStatus,
                                                             output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

/// Single-quotes a string for /bin/sh: `it's` -> `'it'\''s'`.
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Runs a shell command as root through the standard macOS administrator prompt.
/// Used only for one-off fixes the user clicks (e.g. removing a root-owned pid file).
public struct AdminCommand: Sendable {
    public let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    public func run(_ shellCommand: String) async -> CommandResult {
        await runner.run("/usr/bin/osascript", ["-e", Self.appleScript(for: shellCommand)])
    }

    static func appleScript(for shellCommand: String) -> String {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}
