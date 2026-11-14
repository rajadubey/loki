import Foundation

/// Where `sync` fetches machine.json from. Stored in ~/.loki/config as shell variables,
/// the same file the CLI sources, so both stay in step.
public struct SyncSettings: Equatable, Sendable {
    public var user: String
    public var host: String
    public var port: Int
    public var remotePath: String

    /// Defaults match the CLI's (`${LOKI_SSH_USER:-root}` etc.).
    public init(user: String = "root", host: String = "", port: Int = 22, remotePath: String = "/mnt/machines.json") {
        self.user = user
        self.host = host
        self.port = port
        self.remotePath = remotePath
    }

    static let keys = (user: "LOKI_SSH_USER", host: "LOKI_SSH_HOST", port: "LOKI_SSH_PORT", path: "LOKI_REMOTE_MACHINES_JSON")

    public var isConfigured: Bool { !host.isEmpty }

    /// Problems that would make ssh/scp fail or misbehave; empty means usable.
    public var problems: [String] {
        var p: [String] = []
        // A leading "-" would be read by ssh/scp as an option.
        let token = /^[A-Za-z0-9._@:\[\]][A-Za-z0-9._@:\[\]-]*$/
        if host.isEmpty { p.append("Enter the SSH host.") } else if host.wholeMatch(of: token) == nil { p.append("Host “\(host)” has characters ssh won't accept.") }
        if user.isEmpty { p.append("Enter the SSH user.") } else if user.wholeMatch(of: token) == nil { p.append("User “\(user)” has characters ssh won't accept.") }
        if !(1...65535).contains(port) { p.append("Port must be between 1 and 65535.") }
        if remotePath.isEmpty { p.append("Enter the path of machines.json on the host.") }
        return p
    }

    /// Reads `KEY=value`, `KEY="value"`, `KEY='value'` and `export KEY=...` lines; other lines are ignored.
    /// Missing keys keep their defaults, so this also reads LOKI_* exports out of ~/.zshrc.
    public static func parse(_ text: String) -> SyncSettings {
        let values = assignments(in: text)
        var s = SyncSettings()
        if let v = values[keys.user], !v.isEmpty { s.user = v }
        if let v = values[keys.host] { s.host = v }
        if let v = values[keys.port], let n = Int(v) { s.port = n }
        if let v = values[keys.path], !v.isEmpty { s.remotePath = v }
        return s
    }

    /// True if `text` sets any of the sync variables (used to offer importing from shell profiles).
    public static func isPresent(in text: String) -> Bool {
        let found = assignments(in: text)
        return [keys.user, keys.host, keys.port, keys.path].contains { found[$0] != nil }
    }

    /// `existing` config with our four variables replaced (or appended), every other line kept.
    public func serialized(preserving existing: String = "") -> String {
        let ours: [(String, String)] = [(Self.keys.user, user), (Self.keys.host, host),
                                        (Self.keys.port, String(port)), (Self.keys.path, remotePath)]
        var written = Set<String>()
        var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for (i, line) in lines.enumerated() {
            guard let key = Self.assignmentKey(line), let value = ours.first(where: { $0.0 == key })?.1 else { continue }
            lines[i] = "\(key)=\(shellQuote(value))"
            written.insert(key)
        }
        if lines.isEmpty { lines.append("# loki settings, read by the loki app and CLI") }
        for (key, value) in ours where !written.contains(key) {
            lines.append("\(key)=\(shellQuote(value))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func load(from paths: LokiPaths) -> SyncSettings {
        parse((try? String(contentsOf: paths.config, encoding: .utf8)) ?? "")
    }

    public func save(to paths: LokiPaths) throws {
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: paths.config, encoding: .utf8)) ?? ""
        try Data(serialized(preserving: existing).utf8).write(to: paths.config, options: .atomic)
    }

    // MARK: Parsing helpers

    static func assignmentKey(_ line: String) -> String? {
        line.firstMatch(of: /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=/).map { String($0.1) }
    }

    static func assignments(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let m = line.firstMatch(of: /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/) else { continue }
            result[String(m.1)] = unquote(String(m.2))
        }
        return result
    }

    /// `'a'\''b'` -> `a'b`, `"x"` -> `x`, `x # note` -> `x`.
    /// Like the shell, `$HOME` / `${HOME}` expand outside single quotes.
    /// ponytail: only HOME is expanded; other variables stay literal (the app never writes any).
    static func unquote(_ raw: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var out = ""
        var quote: Character?
        let chars = Array(raw.trimmingCharacters(in: .whitespaces))
        var i = 0
        func next() -> Character? {
            guard i < chars.count else { return nil }
            defer { i += 1 }
            return chars[i]
        }
        func expandHome() -> Bool {
            for token in ["{HOME}", "HOME"] where String(chars[i...].prefix(token.count)) == token {
                // "$HOMEDIR" is another variable, not $HOME + "DIR"
                let end = i + token.count
                if token == "HOME", end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" { return false }
                out += home
                i = end
                return true
            }
            return false
        }
        while let ch = next() {
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if q == "\"" && ch == "\\", let escaped = next() {
                    out.append(escaped)
                } else if q == "\"" && ch == "$" && expandHome() {
                    continue
                } else {
                    out.append(ch)
                }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "\\", let escaped = next() {
                out.append(escaped)
            } else if ch == "$" && expandHome() {
                continue
            } else if ch == "#" || ch == ";" {
                break
            } else if ch == " " || ch == "\t" {
                break  // shell assignment value ends at unquoted whitespace
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

public enum SyncError: Error, LocalizedError, Equatable {
    case notConfigured([String])
    case fetchFailed(String)
    case invalidDownload(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let problems): "Sync isn't set up: " + problems.joined(separator: " ")
        case .fetchFailed(let output): "Couldn't fetch machines.json over SSH.\n\(output)"
        case .invalidDownload(let why): "The downloaded file was rejected, so your machines are unchanged. \(why)"
        }
    }
}

/// Fetches machine.json over SSH, non-interactively (key-based auth only, no prompts).
public struct Syncer: Sendable {
    public let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    static func sshOptions(connectTimeout: Int = 8) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)"]
    }

    /// Checks the host is reachable with key auth and the remote file is readable.
    public func testConnection(_ s: SyncSettings) async -> CommandResult {
        guard s.problems.isEmpty else { return CommandResult(status: 2, output: s.problems.joined(separator: "\n")) }
        return await runner.run("ssh", Self.sshOptions() + ["-p", String(s.port), "\(s.user)@\(s.host)",
                                                            "test -r \(shellQuote(s.remotePath)) && echo ok"])
    }

    /// Downloads to a temp file, checks it decodes, then replaces machine.json via `store`
    /// (which validates and keeps machine.json.bak). Returns the new list.
    @discardableResult
    public func sync(_ s: SyncSettings, into store: MachineStore) async throws -> MachineList {
        guard s.problems.isEmpty else { throw SyncError.notConfigured(s.problems) }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "loki-machines-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = await runner.run("scp", Self.sshOptions() + ["-P", String(s.port), "\(s.user)@\(s.host):\(s.remotePath)", tmp.path])
        guard result.succeeded else { throw SyncError.fetchFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        do {
            let machines = try store.decode(Data(contentsOf: tmp), source: "Downloaded machines.json")
            try store.save(machines)
            return machines
        } catch let error as StoreError {
            throw SyncError.invalidDownload(error.errorDescription ?? "")
        }
    }
}
