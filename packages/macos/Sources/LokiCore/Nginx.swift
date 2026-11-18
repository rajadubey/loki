import Foundation

// MARK: - Rendering

public enum NginxConfig {
    /// remote.conf for one machine, byte-for-byte the CLI's format (services sorted by name).
    /// With `includeServices: false` it is just the header, which is how "disconnect" empties the proxy.
    /// Ports listen on 127.0.0.1 only: on every interface, anyone on the same network could use this
    /// Mac to reach the remote machines (VPN-only hosts included).
    public static func render(machineName: String, machine: Machine, includeServices: Bool = true, date: Date = Date()) -> String {
        var out = "# Auto-generated remote.conf for \(oneLine(machineName)) (\(oneLine(machine.ip))) [\(LokiLog.timestamp(date))]\n"
        guard includeServices else { return out }
        for (service, p) in machine.ports.sorted(by: { $0.key < $1.key }) {
            out += "\nupstream \(service) {\n    server \(machine.ip):\(p.remote);\n}\n"
            out += "server {\n    listen 127.0.0.1:\(p.local);\n    proxy_pass \(service);\n}\n"
        }
        return out
    }

    /// For the header comment, which ends at a line break: CR and LF become spaces (the CLI's `one_line`),
    /// so a value nobody checked (disconnect writes the header without checking) can't start a directive.
    public static func oneLine(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { $0 == "\n" || $0 == "\r" ? " " : $0 }))
    }
}

// MARK: - nginx.conf stream include

/// loki's config is a TCP proxy, so nginx.conf needs `stream { include <dir>/remote.conf; }`.
public enum StreamInclude {
    /// True when an uncommented include of `remote.conf` sits inside a top-level `stream { }` block.
    public static func isConfigured(in nginxConf: String) -> Bool {
        let text = stripComments(nginxConf)
        for body in streamBodies(text) where body.firstMatch(of: /(?m)^\s*include\s+["']?(?:[^;"'\s]*\/)?remote\.conf["']?\s*;/) != nil {
            return true
        }
        return false
    }

    /// nginx.conf with the include added: inside the first `stream { }` block if there is one,
    /// otherwise a new block appended at the end. Unchanged if already configured.
    public static func adding(to nginxConf: String, includePath: String) -> String {
        if isConfigured(in: nginxConf) { return nginxConf }
        let line = "    include \(includePath);  # added by loki"
        let text = stripComments(nginxConf)
        if let open = firstStreamOpenBrace(text) {
            // stripComments keeps the character count, so map the position by character offset
            let offset = text.distance(from: text.startIndex, to: open)
            let after = nginxConf.index(nginxConf.startIndex, offsetBy: offset + 1)
            return String(nginxConf[..<after]) + "\n" + line + String(nginxConf[after...])
        }
        let sep = nginxConf.hasSuffix("\n") || nginxConf.isEmpty ? "" : "\n"
        return nginxConf + sep + "\n# TCP proxies managed by loki\nstream {\n" + line + "\n}\n"
    }

    /// Replaces `#` comments with spaces so character offsets stay the same.
    static func stripComments(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inComment = false, quote: Character?
        for ch in s {
            if inComment {
                // isNewline, not == "\n": in a CRLF file "\r\n" is a single Character
                if ch.isNewline { inComment = false; out.append(ch) } else { out.append(" ") }
                continue
            }
            if let q = quote {
                if ch == q { quote = nil }
                out.append(ch)
            } else if ch == "\"" || ch == "'" {
                quote = ch
                out.append(ch)
            } else if ch == "#" {
                inComment = true
                out.append(" ")
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Index of `{` opening each top-level `stream` block (depth 0).
    static func streamOpenBraces(_ text: String) -> [String.Index] {
        var result: [String.Index] = []
        var depth = 0
        var word = ""
        var lastWord = ""
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isLetter || ch.isNumber || ch == "_" {
                word.append(ch)
            } else {
                if !word.isEmpty { lastWord = word; word = "" }
                if ch == "{" {
                    if depth == 0 && lastWord == "stream" { result.append(i) }
                    depth += 1
                    lastWord = ""
                } else if ch == "}" {
                    depth = max(0, depth - 1)
                    lastWord = ""
                } else if ch == ";" {
                    lastWord = ""
                }
            }
            i = text.index(after: i)
        }
        return result
    }

    static func firstStreamOpenBrace(_ text: String) -> String.Index? {
        streamOpenBraces(text).first
    }

    /// Text between each top-level stream block's braces.
    static func streamBodies(_ text: String) -> [Substring] {
        streamOpenBraces(text).compactMap { open in
            var depth = 0
            var i = open
            while i < text.endIndex {
                if text[i] == "{" { depth += 1 }
                if text[i] == "}" {
                    depth -= 1
                    if depth == 0 { return text[text.index(after: open)..<i] }
                }
                i = text.index(after: i)
            }
            return nil
        }
    }
}

// MARK: - Controlling nginx

public enum NginxError: Error, LocalizedError, Equatable {
    case notInstalled
    case confDirectoryNotFound
    case needsRoot(directory: String)
    case writeFailed(String)
    case testFailed(output: String)
    case reloadFailed(output: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "nginx isn't installed. Install it with Homebrew: brew install nginx"
        case .confDirectoryNotFound:
            "Couldn't find nginx's config folder. Check that nginx is installed and `nginx -t` runs."
        case .needsRoot(let dir):
            "nginx here belongs to root (\(dir) isn't writable or nginx runs as root), and the app can't use sudo. Open Setup to switch nginx to run as you."
        case .writeFailed(let why):
            "Couldn't write remote.conf: \(why)"
        case .testFailed(let output):
            "nginx rejected the new config, so the previous one was restored.\n\(output)"
        case .reloadFailed(let output):
            "nginx didn't reload. Is it running? Open Setup to start it.\n\(output)"
        }
    }
}

public struct Nginx: Sendable {
    public let runner: CommandRunner
    /// Tried when `nginx -t` doesn't print a config path.
    public var fallbackConfDirectories = ["/opt/homebrew/etc/nginx", "/usr/local/etc/nginx", "/etc/nginx"]

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    /// First config path nginx prints ("the configuration file /x/nginx.conf syntax is ok"); it prints it
    /// even when the test fails on permissions.
    public static func configPath(fromTestOutput output: String) -> String? {
        output.firstMatch(of: /configuration file (\S+nginx\.conf)/).map { String($0.1) }
    }

    /// `--pid-path=` from `nginx -V`.
    public static func pidPath(fromVersionOutput output: String) -> String? {
        output.firstMatch(of: /--pid-path=(\S+)/).map { String($0.1) }
    }

    public func isInstalled() async -> Bool {
        await runner.run("nginx", ["-v"]).succeeded
    }

    public func test() async -> CommandResult {
        await runner.run("nginx", ["-t"])
    }

    public func reload() async -> CommandResult {
        await runner.run("nginx", ["-s", "reload"])
    }

    /// nginx retitles itself "nginx: master process …", so match the command line, not the name.
    public func isRunning() async -> Bool {
        await runner.run("pgrep", ["-f", "nginx: master"]).succeeded
    }

    public func runsAsRoot() async -> Bool {
        await runner.run("pgrep", ["-u", "0", "-f", "nginx: master"]).succeeded
    }

    public func pidFilePath() async -> String? {
        Self.pidPath(fromVersionOutput: await runner.run("nginx", ["-V"]).output)
    }

    public func configFile() async -> URL? {
        if let path = Self.configPath(fromTestOutput: await test().output),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        for dir in fallbackConfDirectories {
            let file = URL(fileURLWithPath: dir).appending(path: "nginx.conf")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    public func configDirectory() async -> URL? {
        await configFile()?.deletingLastPathComponent()
    }

    /// Installs `config` as <conf dir>/remote.conf, tests it and reloads nginx.
    /// If nginx rejects it, the previous remote.conf is restored (nginx.conf includes it by path,
    /// so it is never deleted). Throws `NginxError`.
    public func install(config: String) async throws {
        guard await isInstalled() else { throw NginxError.notInstalled }
        guard let dir = await configDirectory() else { throw NginxError.confDirectoryNotFound }
        let rootNginx = await runsAsRoot()
        if !FileManager.default.isWritableFile(atPath: dir.path) || rootNginx {
            throw NginxError.needsRoot(directory: dir.path)
        }
        let dest = dir.appending(path: "remote.conf")
        let previous = try? Data(contentsOf: dest)
        do {
            try Data(config.utf8).write(to: dest, options: .atomic)
        } catch {
            throw NginxError.writeFailed(error.localizedDescription)
        }
        let test = await test()
        guard test.succeeded else {
            try? (previous ?? Data()).write(to: dest, options: .atomic)
            throw NginxError.testFailed(output: test.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let reload = await reloadOrStart()
        guard reload.succeeded else {
            throw NginxError.reloadFailed(output: reload.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Starts nginx this many times while the old listen sockets are still bound.
    public var startAttempts = 10
    public var startRetryDelay: Duration = .seconds(1)

    /// `nginx -s reload`, or, when no master is running (e.g. a stale pid file), stop any
    /// stragglers and start nginx, retrying only on "Address already in use".
    /// A running nginx that refuses to reload is a real error and is left alone. Same as loki.sh's reload_nginx.
    public func reloadOrStart() async -> CommandResult {
        let reload = await reload()
        if reload.succeeded { return reload }
        if await isRunning() { return reload }
        _ = await runner.run("pkill", ["-f", "nginx: (master|worker)"])
        var last = reload
        for _ in 0..<max(1, startAttempts) {
            last = await runner.run("nginx", [])
            if last.succeeded { return last }
            // brew services / launchd may have respawned it; then a reload loads our config
            if await isRunning(), await self.reload().succeeded { return CommandResult(status: 0, output: "") }
            guard last.output.contains("Address already in use") else { break }
            try? await Task.sleep(for: startRetryDelay)
        }
        return last
    }
}
