import Foundation

/// Where `sync` fetches machine.json from: an HTTPS URL (e.g. a gist's Raw link) when `url` is set,
/// otherwise a file on an SSH host. Stored in ~/.loki/config as shell variables, the same file the
/// CLI sources, so both stay in step.
public struct SyncSettings: Equatable, Sendable {
    public var user: String
    public var host: String
    public var port: Int
    public var remotePath: String
    public var url: String

    /// Defaults match the CLI's (`${LOKI_SSH_USER:-root}` etc.).
    public init(user: String = "root", host: String = "", port: Int = 22, remotePath: String = "/mnt/machines.json", url: String = "") {
        self.user = user
        self.host = host
        self.port = port
        self.remotePath = remotePath
        self.url = url
    }

    static let keys = (user: "LOKI_SSH_USER", host: "LOKI_SSH_HOST", port: "LOKI_SSH_PORT", path: "LOKI_REMOTE_MACHINES_JSON",
                       url: "LOKI_SYNC_URL")

    /// A URL wins over SSH, as in the CLI.
    public var usesURL: Bool { !url.isEmpty }

    public var isConfigured: Bool { usesURL || !host.isEmpty }

    /// Where sync reads from, for the log and Setup. A URL's query and fragment are left out:
    /// they may carry an access token, which must not end up in loki.log.
    public var source: String {
        usesURL ? String(url.prefix { $0 != "?" && $0 != "#" }) : "\(user)@\(host):\(remotePath)"
    }

    /// Problems that would make the download fail or misbehave; empty means usable.
    public var problems: [String] {
        if usesURL { return Self.urlProblems(url) }
        var p: [String] = []
        // A leading "-" would be read by ssh/scp as an option.
        let token = /^[A-Za-z0-9._@:\[\]][A-Za-z0-9._@:\[\]-]*$/
        if host.isEmpty { p.append("Enter the SSH host.") } else if host.wholeMatch(of: token) == nil { p.append("Host “\(host)” has characters ssh won't accept.") }
        if user.isEmpty { p.append("Enter the SSH user.") } else if user.wholeMatch(of: token) == nil { p.append("User “\(user)” has characters ssh won't accept.") }
        if !(1...65535).contains(port) { p.append("Port must be between 1 and 65535.") }
        if remotePath.isEmpty { p.append("Enter the path of machines.json on the host.") }
        return p
    }

    /// HTTPS only (as in the CLI, which hands the URL to curl restricted to https), no credentials
    /// (the URL is saved in plain text), and a gist's Raw link rather than its HTML page. No quotes,
    /// backslashes or line breaks: none belong in a URL, and the URL goes into curl's config as "…".
    static func urlProblems(_ url: String) -> [String] {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "\"\\"))
        guard url.hasPrefix("https://"), url.rangeOfCharacter(from: forbidden) == nil,
              let parts = URLComponents(string: url), let host = parts.host, !host.isEmpty else {
            return ["The URL must be a full https:// address without spaces, quotes or backslashes."]
        }
        if parts.user != nil || parts.password != nil {
            return ["Leave the user name and password out of the URL: it's saved in plain text in ~/.loki/config."]
        }
        if host.lowercased() == "gist.github.com" {
            return ["That's the gist's page. Use its Raw link, which starts with https://gist.githubusercontent.com/."]
        }
        return []
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
        if let v = values[keys.url] { s.url = v }
        return s
    }

    /// True if `text` sets any of the sync variables (used to offer importing from shell profiles).
    public static func isPresent(in text: String) -> Bool {
        let found = assignments(in: text)
        return [keys.user, keys.host, keys.port, keys.path, keys.url].contains { found[$0] != nil }
    }

    /// `existing` config with our variables replaced (or appended), every other line kept.
    public func serialized(preserving existing: String = "") -> String {
        let ours: [(String, String)] = [(Self.keys.user, user), (Self.keys.host, host),
                                        (Self.keys.port, String(port)), (Self.keys.path, remotePath), (Self.keys.url, url)]
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

    /// Owner-only (0600): the CLI sources this file as shell code and refuses it when others can write it.
    public func save(to paths: LokiPaths) throws {
        try paths.ensurePrivateHome()
        let existing = (try? String(contentsOf: paths.config, encoding: .utf8)) ?? ""
        try writePrivately(Data(serialized(preserving: existing).utf8), to: paths.config)
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
        case .fetchFailed(let output): "Couldn't download machines.json.\n\(output)"
        case .invalidDownload(let why): "The downloaded file was rejected, so your machines are unchanged. \(why)"
        }
    }
}

/// Fetches machine.json over HTTPS with curl, or over SSH non-interactively (key-based auth only, no prompts).
public struct Syncer: Sendable {
    public let runner: CommandRunner

    /// A machine list is a few KB; a download past this isn't one.
    public static let maxDownloadBytes = 1_000_000

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    static func sshOptions(connectTimeout: Int = 8) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)"]
    }

    /// The CLI runs curl with the same flags. `-q` must come first: it skips ~/.curlrc, which could
    /// turn off certificate checks. The URL comes from `config` (-K), never the command line, where
    /// any user of the Mac could read it with `ps`. Only https, redirects included; size and time capped.
    static func curlArguments(config: String, output: String) -> [String] {
        ["-q", "-K", config, "-fsSL", "--proto", "=https", "--proto-redir", "=https", "--max-filesize", String(maxDownloadBytes),
         "--max-time", "30", "-o", output]
    }

    /// Checks the host is reachable with key auth and the remote file is readable.
    public func testConnection(_ s: SyncSettings) async -> CommandResult {
        guard s.problems.isEmpty else { return CommandResult(status: 2, output: s.problems.joined(separator: "\n")) }
        return await runner.run("ssh", Self.sshOptions() + ["-p", String(s.port), "\(s.user)@\(s.host)",
                                                            "test -r \(shellQuote(s.remotePath)) && echo ok"])
    }

    /// Downloads machine.json to a temp file and checks it the way saving would: valid JSON, safe names,
    /// addresses and ports. Changes nothing, so it also backs "Test connection" for a URL.
    public func fetch(_ s: SyncSettings) async throws -> MachineFile {
        guard s.problems.isEmpty else { throw SyncError.notConfigured(s.problems) }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "loki-machines-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result: CommandResult
        if s.usesURL {
            // A private temp file (TMPDIR is per user); urlProblems rules out anything that could end the "…"
            let config = FileManager.default.temporaryDirectory.appending(path: "loki-curl-\(UUID().uuidString).conf")
            defer { try? FileManager.default.removeItem(at: config) }
            try writePrivately(Data("url = \"\(s.url)\"\n".utf8), to: config)
            result = await runner.run("curl", Self.curlArguments(config: config.path, output: tmp.path))
        } else {
            result = await runner.run("scp", Self.sshOptions() + ["-P", String(s.port), "\(s.user)@\(s.host):\(s.remotePath)", tmp.path])
        }
        guard result.succeeded else { throw SyncError.fetchFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        // scp has no size cap of its own, so check before reading it into memory
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? Int ?? 0
        guard size <= Self.maxDownloadBytes else {
            throw SyncError.invalidDownload("It's over \(Self.maxDownloadBytes / 1_000_000) MB, which no machine list is.")
        }
        do {
            let file = try MachineStore.decode(Data(contentsOf: tmp), source: "Downloaded machines.json")
            let issues = validate(file)
            guard issues.isEmpty else { throw StoreError.invalid(issues) }
            return file
        } catch let error as StoreError {
            throw SyncError.invalidDownload(error.errorDescription ?? "")
        }
    }

    /// `fetch`, then replaces machine.json via `store` (which keeps machine.json.bak). Returns the new file.
    @discardableResult
    public func sync(_ s: SyncSettings, into store: MachineStore) async throws -> MachineFile {
        let file = try await fetch(s)
        try store.save(file)
        return file
    }
}
