import Foundation
import Testing
@testable import LokiCore

// MARK: - Sandbox (shared with IntegrationTests.swift; distinctive name to avoid clashing with other test helpers)

/// A throwaway world for one test: `home/.loki`, `conf/nginx.conf` and a `bin/` of fake
/// nginx / pgrep / sudo / scp scripts placed first on PATH. Never touches the real ~/.loki or nginx.
/// Markers in the root change the fakes: `fail-test` (nginx -t fails), `fail-reload`
/// (nginx -s reload fails), `root-nginx` (pgrep finds a root nginx master).
final class ParitySandbox: @unchecked Sendable {
    /// …/packages/macos/Tests/LokiCoreTests/ParityTests.swift → …/packages/cli/loki.sh
    static let cliScript = URL(fileURLWithPath: #filePath).absoluteURL
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "cli/loki.sh")
    /// The CLI runs with PATH=<bin>:/usr/bin:/bin, so jq must be in one of those.
    static let hasJQ = ["/usr/bin/jq", "/bin/jq"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    static let noJQ = "jq isn't in /usr/bin or /bin; the CLI needs it, so CLI tests are skipped"

    let root: URL
    let paths: LokiPaths
    let engine: LokiEngine
    private let cliRunner: ProcessRunner
    let shell: ProcessRunner

    var conf: URL { root.appending(path: "conf") }
    /// remote.conf as installed next to nginx.conf.
    var installed: String? { Self.read(conf.appending(path: "remote.conf")) }
    var activeBytes: Data? { try? Data(contentsOf: paths.active) }

    init(machines json: String? = nil) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(path: "loki-parity-\(UUID().uuidString)")
        let bin = root.appending(path: "bin")
        for dir in [bin, root.appending(path: "home/.loki"), root.appending(path: "conf")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("events {}\n".utf8).write(to: root.appending(path: "conf/nginx.conf"))
        let r = root.path, nginxConf = "\(root.path)/conf/nginx.conf"
        let fakes = [
            "nginx": """
            echo "$*" >> '\(r)/nginx.calls'
            case "$1" in
              -t)
                if [ -e '\(r)/fail-test' ]; then
                  echo "nginx: [emerg] unexpected end of file in \(r)/conf/remote.conf:2" >&2
                  echo "nginx: configuration file \(nginxConf) test failed" >&2
                  exit 1
                fi
                echo "nginx: the configuration file \(nginxConf) syntax is ok" >&2
                echo "nginx: configuration file \(nginxConf) test is successful" >&2 ;;
              -s)
                if [ -e '\(r)/fail-reload' ]; then echo 'nginx: [error] invalid PID number "" in "\(r)/nginx.pid"' >&2; exit 1; fi ;;
              *) echo "nginx version: nginx/1.27.0 (fake)" >&2 ;;
            esac
            """,
            "pgrep": "[ -e '\(r)/root-nginx' ]",
            // Safety net: the CLI must never get to real sudo from a test.
            "sudo": "echo \"fake sudo refused: $*\" >&2; exit 1",
            // scp [opts] user@host:/path dest -> cp /path dest
            "scp": """
            echo "$*" >> '\(r)/scp.calls'
            for a; do src=$dst; dst=$a; done
            cp "${src#*:}" "$dst"
            """,
        ]
        for (name, body) in fakes {
            let url = bin.appending(path: name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let path = "\(bin.path):/usr/bin:/bin"
        paths = LokiPaths(home: root.appending(path: "home/.loki"))
        engine = LokiEngine(paths: paths, runner: ProcessRunner(path: path))
        // Blank any LOKI_* settings leaking in from the developer's shell.
        let clean = ["BASH_ENV": "", "LOKI_SSH_USER": "", "LOKI_SSH_HOST": "", "LOKI_SSH_PORT": "", "LOKI_REMOTE_MACHINES_JSON": ""]
        shell = ProcessRunner(path: path, environment: clean)
        cliRunner = ProcessRunner(path: path, environment: clean.merging(["HOME": root.appending(path: "home").path]) { $1 })
        if let json { try writeMachines(json) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func writeMachines(_ json: String) throws {
        try Data(json.utf8).write(to: paths.machines)
    }

    /// `bash loki.sh <args>` with HOME=<sandbox>/home; stdout and stderr combined, colors stripped.
    @discardableResult
    func cli(_ args: String...) async -> CommandResult {
        let r = await cliRunner.run("/bin/bash", [Self.cliScript.path] + args)
        return CommandResult(status: r.status, output: Self.stripANSI(r.output))
    }

    func mark(_ marker: String) { FileManager.default.createFile(atPath: root.appending(path: marker).path, contents: nil) }

    /// Argument lines a fake tool was called with ("nginx" or "scp").
    func calls(_ tool: String) -> [String] {
        (Self.read(root.appending(path: "\(tool).calls")) ?? "").split(separator: "\n").map(String.init)
    }

    static func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    /// `[2026-11-13 10:00:00]` -> `[TS]`, the only part of remote.conf that differs between runs.
    static func normalized(_ s: String?) -> String? {
        s?.replacing(/\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]/, with: "[TS]")
    }

    static func stripANSI(_ s: String) -> String { s.replacing(/\u{1B}\[[0-9;]*m/, with: "") }
}

// MARK: - Fixtures

private struct Fixture: Sendable, CustomTestStringConvertible {
    let name: String
    let json: String
    var testDescription: String { name }
}

/// Every fixture has a machine "dev"; most also have "prod".
private let fixtures: [Fixture] = [
    Fixture(name: "multiple services", json: """
    {"prod": {"ip": "10.0.0.9", "services": {"web": {"local": 8081, "remote": 80}}},
     "dev": {"ip": "10.0.0.5", "services": {
        "web": {"local": 8080, "remote": 80}, "db": {"local": 5432, "remote": 5432}, "api": {"local": 9000, "remote": 3000}}}}
    """),
    Fixture(name: "null and missing ports", json: """
    {"dev": {"ip": "192.168.1.20", "services": {
        "ok": {"local": 7000, "remote": 7001}, "nolocal": {"local": null, "remote": 80},
        "noremote": {"local": 8000, "remote": null}, "missing": {"local": 8100}, "z": {"remote": 9}}},
     "prod": {"ip": "10.0.0.9", "services": {}}}
    """),
    Fixture(name: "unsorted keys, mixed case and punctuation", json: """
    {"zeta": {"services": {}, "ip": "1.1.1.1"},
     "dev": {"services": {"b_svc": {"remote": 2, "local": 1002}, "Web": {"remote": 3, "local": 1003},
        "a-b": {"remote": 4, "local": 1004}, "_x": {"remote": 5, "local": 1005}, "a1": {"remote": 6, "local": 1006},
        "A": {"remote": 7, "local": 1007}}, "ip": "dev.example.internal"},
     "prod": {"services": {"web": {"remote": 80, "local": 8081}}, "ip": "10.0.0.9"}}
    """),
    Fixture(name: "one service", json: """
    {"dev": {"ip": "10.1.2.3", "services": {"ssh": {"local": 2222, "remote": 22}}},
     "prod": {"ip": "10.0.0.9", "services": {"web": {"local": 8081, "remote": 80}}}}
    """),
    Fixture(name: "zero services", json: """
    {"dev": {"ip": "10.1.2.4", "services": {}}, "prod": {"ip": "10.0.0.9", "services": {"web": {"local": 8081, "remote": 80}}}}
    """),
]

/// Two sandboxes with the same machine.json: one driven by the CLI, one by the engine.
private func twins(_ json: String) throws -> (cli: ParitySandbox, app: ParitySandbox) {
    (try ParitySandbox(machines: json), try ParitySandbox(machines: json))
}

private func expectSameState(_ cli: ParitySandbox, _ app: ParitySandbox, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(ParitySandbox.normalized(cli.installed) == ParitySandbox.normalized(app.installed), "installed remote.conf", sourceLocation: sourceLocation)
    #expect(ParitySandbox.normalized(ParitySandbox.read(cli.paths.generatedConf)) == ParitySandbox.normalized(ParitySandbox.read(app.paths.generatedConf)),
            "~/.loki/remote.conf", sourceLocation: sourceLocation)
    #expect(cli.activeBytes == app.activeBytes, "~/.loki/active", sourceLocation: sourceLocation)
}

// MARK: - Tests

@Suite(.disabled(if: !ParitySandbox.hasJQ, Comment(rawValue: ParitySandbox.noJQ)))
struct ParityTests {
    @Test(arguments: fixtures)
    fileprivate func connectWritesTheSameFiles(_ f: Fixture) async throws {
        let (cli, app) = try twins(f.json)
        let r = await cli.cli("connect", "dev")
        #expect(r.succeeded, "\(r.output)")
        try await app.engine.connect("dev")

        expectSameState(cli, app)
        #expect(app.activeBytes == Data("dev\n".utf8))
        let header = try #require(app.installed?.split(separator: "\n").first)
        #expect(header.wholeMatch(of: /# Auto-generated remote.conf for dev \(.+\) \[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]/) != nil)
    }

    @Test(arguments: fixtures)
    fileprivate func reloadWritesTheSameFiles(_ f: Fixture) async throws {
        let (cli, app) = try twins(f.json)
        await cli.cli("connect", "dev")
        try await app.engine.connect("dev")
        // Edit machine.json between connect and reload, as a user would.
        let edited = f.json.replacingOccurrences(of: "\"dev\":", with: "\"old\":")
            .replacingOccurrences(of: "\"prod\":", with: "\"dev\":")
        try cli.writeMachines(edited)
        try app.writeMachines(edited)

        let r = await cli.cli("reload")
        #expect(r.succeeded, "\(r.output)")
        try await app.engine.reload()
        expectSameState(cli, app)
        #expect(app.installed?.contains("10.0.0.9") == true)
    }

    @Test(arguments: fixtures)
    fileprivate func disconnectWritesTheSameHeaderOnlyFile(_ f: Fixture) async throws {
        let (cli, app) = try twins(f.json)
        await cli.cli("connect", "dev")
        try await app.engine.connect("dev")

        let r = await cli.cli("disconnect")
        #expect(r.succeeded, "\(r.output)")
        try await app.engine.disconnect()
        expectSameState(cli, app)
        #expect(app.activeBytes == nil)
        #expect(app.installed?.split(separator: "\n").count == 1)
    }

    @Test func rejectedConfigKeepsThePreviousOneInBoth() async throws {
        let (cli, app) = try twins(fixtures[0].json)
        await cli.cli("connect", "dev")
        try await app.engine.connect("dev")
        let (cliBefore, appBefore) = (cli.installed, app.installed)
        cli.mark("fail-test")
        app.mark("fail-test")

        let r = await cli.cli("connect", "prod")
        #expect(!r.succeeded)
        await #expect(throws: NginxError.self) { try await app.engine.connect("prod") }
        #expect(cli.installed == cliBefore)
        #expect(app.installed == appBefore)
        expectSameState(cli, app)
        #expect(app.activeBytes == Data("dev\n".utf8))
    }

    @Test func rejectedFirstConfigLeavesAnEmptyFileInBoth() async throws {
        let (cli, app) = try twins(fixtures[0].json)
        cli.mark("fail-test")
        app.mark("fail-test")
        #expect(await !cli.cli("connect", "dev").succeeded)
        await #expect(throws: NginxError.self) { try await app.engine.connect("dev") }
        #expect(cli.installed == "")
        #expect(app.installed == "")
        expectSameState(cli, app)
    }

    @Test func failedReloadLeavesTheSameStateInBoth() async throws {
        let (cli, app) = try twins(fixtures[0].json)
        cli.mark("fail-reload")
        app.mark("fail-reload")
        #expect(await !cli.cli("connect", "dev").succeeded)
        await #expect(throws: NginxError.self) { try await app.engine.connect("dev") }
        // nginx accepted the file, so it stays installed; but 'active' is not set.
        expectSameState(cli, app)
        #expect(app.activeBytes == nil)
        #expect(app.installed?.contains("upstream web") == true)
    }

    @Test func unknownMachineChangesNothingInBoth() async throws {
        let (cli, app) = try twins(fixtures[0].json)
        #expect(await !cli.cli("connect", "nope").succeeded)
        await #expect(throws: EngineError.unknownMachine("nope")) { try await app.engine.connect("nope") }
        expectSameState(cli, app)
        #expect(app.installed == nil)
        #expect(cli.calls("nginx").isEmpty)
    }

    @Test func logLinesUseTheSameFormat() async throws {
        let (cli, app) = try twins(fixtures[0].json)
        await cli.cli("connect", "dev")
        try await app.engine.connect("dev")
        try await app.engine.disconnect()
        let prefix = /\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] .*/
        let appLines = try #require(ParitySandbox.read(app.paths.log)).split(separator: "\n")
        let cliLines = try #require(ParitySandbox.read(cli.paths.log)).split(separator: "\n")
        #expect(!appLines.isEmpty && !cliLines.isEmpty)
        #expect(appLines.allSatisfy { $0.wholeMatch(of: prefix) != nil }, "\(appLines)")
        // Every entry starts with the prefix in both.
        #expect(cliLines.first?.wholeMatch(of: prefix) != nil)
        do {  // regression check: this was a known CLI/engine mismatch, now fixed
            #expect(cliLines.allSatisfy { $0.wholeMatch(of: prefix) != nil }, "\(cliLines.filter { $0.wholeMatch(of: prefix) == nil })")
        }
    }

    @Test func machinesSavedBySwiftWorkInTheCLI() async throws {
        let cli = try ParitySandbox()
        let machines: MachineList = [
            "zeta": Machine(ip: "10.9.9.9", services: [:]),
            "alpha": Machine(ip: "10.0.0.1", services: ["web": Ports(local: 8080, remote: 80), "db": Ports(local: 5432, remote: 5432)]),
            "mid.box-1": Machine(ip: "host.example", services: ["ssh": Ports(local: 2222, remote: 22)]),
        ]
        try MachineStore(paths: cli.paths).save(machines)

        let list = await cli.cli("list")
        #expect(list.succeeded, "\(list.output)")
        #expect(list.output == "Available machines:\n  - alpha\n  - mid.box-1\n  - zeta\n")

        let r = await cli.cli("connect", "alpha")
        #expect(r.succeeded, "\(r.output)")
        let expected = NginxConfig.render(machineName: "alpha", machine: machines["alpha"]!)
        #expect(ParitySandbox.normalized(cli.installed) == ParitySandbox.normalized(expected))
        #expect(await cli.cli("list").output.contains("  * alpha\n"))
    }

    @Test func syncFetchesAndReloadsTheSameWayInBoth() async throws {
        let (cli, app) = try twins(fixtures[0].json)
        await cli.cli("connect", "dev")
        try await app.engine.connect("dev")
        // Path with a space and a quote: proves the CLI reads Swift's quoting in ~/.loki/config.
        let upstreamDir = cli.root.appending(path: "up stream")
        try FileManager.default.createDirectory(at: upstreamDir, withIntermediateDirectories: true)
        let upstream = upstreamDir.appending(path: "it's machines.json")
        try Data(fixtures[3].json.utf8).write(to: upstream)  // dev now has one service
        let settings = SyncSettings(user: "deploy", host: "fake-host", port: 2222, remotePath: upstream.path)
        try settings.save(to: cli.paths)

        let r = await cli.cli("sync")
        #expect(r.succeeded, "\(r.output)")
        try await app.engine.sync(settings)

        expectSameState(cli, app)
        #expect(app.installed?.contains("upstream ssh") == true)
        #expect(try MachineStore(paths: cli.paths).load() == MachineStore(paths: app.paths).load())
        // The CLI downloads beside machine.json, then swaps it in
        #expect(cli.calls("scp").last?.hasSuffix("-P 2222 deploy@fake-host:\(upstream.path) \(cli.paths.machines.path).tmp") == true)
        #expect(app.calls("scp").last?.contains("-P 2222 deploy@fake-host:\(upstream.path) ") == true)
    }

    @Test func syncDropsAMachineThatWasRemovedInBoth() async throws {
        let (cli, app) = try twins(fixtures[0].json)
        await cli.cli("connect", "dev")
        try await app.engine.connect("dev")
        let upstream = cli.root.appending(path: "machines.json")
        try Data(#"{"prod": {"ip": "10.0.0.9", "services": {}}}"#.utf8).write(to: upstream)
        let settings = SyncSettings(host: "fake-host", remotePath: upstream.path)
        try settings.save(to: cli.paths)

        await cli.cli("sync")
        try await app.engine.sync(settings)

        #expect(app.activeBytes == nil)
        #expect(app.installed?.contains("upstream") == false)
        #expect(cli.installed?.contains("upstream") == false)
        do {  // regression check: this was a known CLI/engine mismatch, now fixed
            expectSameState(cli, app)
        }
    }

    // MARK: ~/.loki/config

    @Test(arguments: [
        SyncSettings(user: "root", host: "build.example.com", port: 22, remotePath: "/mnt/machines.json"),
        SyncSettings(user: "deploy", host: "10.0.0.7", port: 2222, remotePath: "/srv/with space/machines.json"),
        SyncSettings(user: "o'brien", host: "my host", port: 65535, remotePath: "/it's/a \"quoted\" $HOME `x` path.json"),
    ])
    func configWrittenBySwiftIsSourcedByTheCLI(_ settings: SyncSettings) async throws {
        let box = try ParitySandbox()
        try settings.save(to: box.paths)
        #expect(try await sourced(box, box.paths.config) == [settings.user, settings.host, String(settings.port), settings.remotePath])
        #expect(SyncSettings.load(from: box.paths) == settings)
    }

    @Test(arguments: [
        #"export LOKI_SSH_HOST="x""#,
        "LOKI_SSH_USER=deploy\nLOKI_SSH_HOST=box.local\nLOKI_SSH_PORT=2200\n",
        "# settings\nexport LOKI_REMOTE_MACHINES_JSON='/srv/m.json' # where it lives\nexport LOKI_SSH_HOST=h",
        #"LOKI_SSH_HOST="host with space""#,
        #"LOKI_SSH_HOST='it'\''s'"#,
        #"LOKI_SSH_HOST="say \"hi\"""#,
        "LOKI_SSH_HOST=first\nLOKI_SSH_HOST=second",
        "LOKI_SSH_USER=\"\"\nLOKI_SSH_PORT=\nLOKI_SSH_HOST=h",
        "  export   LOKI_SSH_HOST=indented",
    ])
    func handWrittenConfigParsesLikeBash(_ text: String) async throws {
        let box = try ParitySandbox()
        try Data(text.utf8).write(to: box.paths.config)
        let s = SyncSettings.parse(text)
        #expect(try await sourced(box, box.paths.config) == [s.user, s.host, String(s.port), s.remotePath])
    }

    @Test func handWrittenConfigWithVariablesParsesLikeBash() async throws {
        let box = try ParitySandbox()
        let text = #"export LOKI_SSH_HOST=h"# + "\n" + #"export LOKI_REMOTE_MACHINES_JSON="$HOME/machines.json""#
        try Data(text.utf8).write(to: box.paths.config)
        let s = SyncSettings.parse(text)
        let bash = try await sourced(box, box.paths.config)
        do {  // regression check: this was a known CLI/engine mismatch, now fixed
            #expect(bash[3] == s.remotePath)
        }
    }

    /// The four values loki.sh's cmd_sync would use after sourcing `config`, with its defaults.
    private func sourced(_ box: ParitySandbox, _ config: URL) async throws -> [String] {
        let script = #"""
            . "$1"
            printf '%s\n' "${LOKI_SSH_USER:-root}" "$LOKI_SSH_HOST" "${LOKI_SSH_PORT:-22}" "${LOKI_REMOTE_MACHINES_JSON:-/mnt/machines.json}"
            """#
        let r = await box.shell.run("/bin/bash", ["-c", script, "bash", config.path])
        try #require(r.succeeded, "\(r.output)")
        return r.output.components(separatedBy: "\n").dropLast().map { $0 }
    }
}
