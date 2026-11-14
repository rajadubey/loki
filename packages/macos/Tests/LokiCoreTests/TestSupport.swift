import Foundation
@testable import LokiCore

/// Recording fake `CommandRunner`. Scripted results are matched on command + exact arguments
/// (returned in order, the last one repeating), then on a per-command handler, else `fallback`.
/// Re-scripting a command + arguments replaces whatever was scripted for it before.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    typealias Handler = @Sendable (_ command: String, _ arguments: [String]) -> CommandResult

    private let lock = NSLock()
    private var scripted: [[String]: [CommandResult]] = [:]
    private var handlers: [[String]: Handler] = [:]
    private var commandHandlers: [String: Handler] = [:]
    private var recorded: [[String]] = []
    /// Unscripted commands fail like a missing binary, so e.g. `pgrep -u 0` means "not root".
    let fallback = CommandResult(status: 127, output: "fake: not scripted")

    static let ok = CommandResult(status: 0, output: "")
    static func ok(_ output: String) -> CommandResult { CommandResult(status: 0, output: output) }
    static func fail(_ output: String = "", status: Int32 = 1) -> CommandResult { CommandResult(status: status, output: output) }

    func on(_ command: String, _ arguments: [String], _ results: CommandResult...) {
        lock.withLock { scripted[[command] + arguments] = results; handlers[[command] + arguments] = nil }
    }

    func on(_ command: String, _ arguments: [String], handler: @escaping Handler) {
        lock.withLock { handlers[[command] + arguments] = handler; scripted[[command] + arguments] = nil }
    }

    /// Any call of `command` not matched exactly (e.g. scp, whose last argument is a random temp path).
    func onAny(_ command: String, handler: @escaping Handler) {
        lock.withLock { commandHandlers[command] = handler }
    }

    /// Every call so far, as `[command] + arguments`.
    var calls: [[String]] { lock.withLock { recorded } }

    func calls(to command: String) -> [[String]] { calls.filter { $0.first == command } }

    func run(_ command: String, _ arguments: [String]) async -> CommandResult {
        let key = [command] + arguments
        let action: Handler? = lock.withLock {
            recorded.append(key)
            if var queue = scripted[key], let first = queue.first {
                if queue.count > 1 { queue.removeFirst(); scripted[key] = queue }
                return { _, _ in first }
            }
            return handlers[key] ?? commandHandlers[command]
        }
        return action?(command, arguments) ?? fallback
    }

    // MARK: nginx

    static func nginxTestOutput(_ conf: URL, ok: Bool = true) -> String {
        ok ? "nginx: the configuration file \(conf.path) syntax is ok\nnginx: configuration file \(conf.path) test is successful\n"
           : "nginx: [emerg] unexpected \"}\" in \(conf.deletingLastPathComponent().path)/remote.conf:3\nnginx: configuration file \(conf.path) test failed\n"
    }

    /// An installed, user-owned nginx whose `nginx -t` names `<confDir>/nginx.conf` (created if missing).
    @discardableResult
    func scriptNginx(confDir: URL, testOK: Bool = true, nginxConf: String = "events {}\n") throws -> URL {
        let conf = confDir.appending(path: "nginx.conf")
        try FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: conf.path) {
            try Data(nginxConf.utf8).write(to: conf)
        }
        on("nginx", ["-v"], Self.ok("nginx version: nginx/1.27.0\n"))
        on("nginx", ["-t"], CommandResult(status: testOK ? 0 : 1, output: Self.nginxTestOutput(conf, ok: testOK)))
        on("nginx", ["-s", "reload"], Self.ok)
        return conf
    }
}

/// A fresh directory under the system temp folder, removed (permissions restored first) on deinit.
/// Keep it in a stored property (e.g. of the test suite) so it outlives the test body.
final class TempDir: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "loki-unit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        if let items = fm.enumerator(atPath: url.path) {
            for case let item as String in items {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appending(path: item).path)
            }
        }
        try? fm.removeItem(at: url)
    }

    func path(_ name: String) -> URL { url.appending(path: name) }

    @discardableResult
    func write(_ name: String, _ text: String) throws -> URL {
        let file = path(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    func read(_ name: String) -> String? {
        try? String(contentsOf: path(name), encoding: .utf8)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: path(name).path)
    }
}
