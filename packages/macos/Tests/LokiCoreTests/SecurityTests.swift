import Foundation
import Testing
@testable import LokiCore

/// What keeps loki safe with untrusted input: machine lists from a sync host or URL, a URL typed
/// into Settings, a GitHub API response, and other users of the same Mac. The CLI's side of the
/// same rules is in packages/cli/tests/run.sh (test_security_*); ParityTests checks both agree.
@Suite struct SecurityTests {
    let tmp: TempDir
    let paths: LokiPaths
    let runner = FakeRunner()

    init() throws {
        tmp = try TempDir()
        paths = LokiPaths(home: tmp.path(".loki"))
    }

    // MARK: ~/.loki is private

    @Test func dataFolderAndEveryFileLokiWritesAreOwnerOnly() throws {
        let store = MachineStore(paths: paths)
        try store.save(MachineFile(machines: ["m": Machine(ip: "10.0.0.1", services: [:])]))
        try store.save(MachineFile(machines: ["m": Machine(ip: "10.0.0.2", services: [:])]))  // second save writes machine.json.bak
        try store.setActive("m")
        try SyncSettings(host: "h").save(to: paths)
        LokiLog(url: paths.log).append("hello")

        #expect(mode(paths.home) == 0o700)
        for file in [paths.machines, paths.home.appending(path: "machine.json.bak"), paths.active, paths.config, paths.log] {
            #expect(mode(file) == 0o600, "\(file.lastPathComponent)")
        }
    }

    @Test func aWorldReadableFolderFromAnOlderVersionIsTightenedAtLaunch() throws {
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try tmp.write(".loki/config", "LOKI_SSH_HOST=h\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: paths.config.path)
        try paths.makePrivate()
        #expect(mode(paths.home) == 0o700)
        // Files keep their mode: quietly fixing a world-writable config would hide what the CLI must refuse
        #expect(mode(paths.config) == 0o666)
    }

    @Test func aLogLokiCantWriteToIsNeverReplaced() throws {
        // e.g. root-owned after a `sudo loki`: the line is skipped, the history kept
        let log = try tmp.write(".loki/loki.log", "[2020-01-01 00:00:00] history\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: log.path)
        LokiLog(url: log).append("new line")
        #expect(tmp.read(".loki/loki.log") == "[2020-01-01 00:00:00] history\n")
        #expect(mode(log) == 0o444)
    }

    @Test func aBackupOfAWorldReadableFileIsPrivateToo() throws {
        try tmp.write(".loki/machine.json", #"{"old": {"ip": "1.1.1.1", "services": {}}}"#)  // as an old CLI left it: 0644
        try MachineStore(paths: paths).save(MachineFile(machines: ["new": Machine(ip: "2.2.2.2", services: [:])]))
        #expect(mode(paths.home.appending(path: "machine.json.bak")) == 0o600)
    }

    @Test func theLogIsRotatedInsteadOfGrowingForever() throws {
        let old = String(repeating: "x", count: LokiLog.maxBytes) + "\n"
        try tmp.write(".loki/loki.log", old)
        LokiLog(url: paths.log).append("after rotation")

        #expect(tmp.read(".loki/loki.log.1") == old)
        let current = try #require(tmp.read(".loki/loki.log"))
        #expect(current.hasSuffix("] after rotation\n") && current.count < 100)
        #expect(mode(paths.log) == 0o600)
    }

    // MARK: Sync URL

    @Test(arguments: [
        "http://example.com/machine.json",                     // plain HTTP: readable and changeable on the way
        "HTTPS://example.com/machine.json",                    // the CLI only accepts a lowercase https://
        "ftp://example.com/machine.json",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "https://",
        "https:// example.com/machine.json",
        "https://example.com/machine.json\nLOKI_SSH_HOST=evil", // a newline would add a line to ~/.loki/config
        "https://user:secret@example.com/machine.json",         // credentials would be saved in plain text
        "https://token@example.com/machine.json",
        "https://gist.github.com/someone/0123abcd",             // the gist's HTML page, not the file
        #"https://example.com/a"b"#,                           // would end the "…" in curl's config
        #"https://example.com/a\b"#,
    ])
    func unsafeOrWrongSyncURLsAreRefusedBeforeAnythingRuns(_ url: String) async {
        let settings = SyncSettings(url: url)
        #expect(!settings.problems.isEmpty)
        await #expect(throws: SyncError.self) { try await Syncer(runner: runner).fetch(settings) }
        #expect(runner.calls.isEmpty)
    }

    @Test(arguments: [
        "https://gist.githubusercontent.com/someone/0123abcd/raw/machine.json",
        "https://raw.githubusercontent.com/org/repo/main/machine.json?token=abc",
        "https://intranet.example:8443/loki/machine.json",
    ])
    func httpsURLsAreAccepted(_ url: String) {
        #expect(SyncSettings(url: url).problems.isEmpty)
    }

    @Test func curlSkipsCurlrcStaysOnHTTPSAndNeverShowsTheURLInPs() async throws {
        let config = Locked<(path: String, text: String?)?>(nil)
        runner.onAny("curl") { command, args in
            if let i = args.firstIndex(of: "-K") {  // read while curl would: the file is gone afterwards
                config.value = (args[i + 1], try? String(contentsOfFile: args[i + 1], encoding: .utf8))
            }
            return curlWriting("{}")(command, args)
        }
        _ = try await Syncer(runner: runner).fetch(SyncSettings(url: "https://example.com/m.json?token=s3cret"))
        let args = try #require(runner.calls(to: "curl").first).dropFirst()
        #expect(args.first == "-q", "-q only works as the first argument; ~/.curlrc could say `insecure`")
        let joined = args.joined(separator: " ")
        for flag in ["--proto =https", "--proto-redir =https", "--max-filesize \(Syncer.maxDownloadBytes)", "--max-time 30"] {
            #expect(joined.contains(flag), "\(flag) in \(joined)")
        }
        #expect(!joined.contains("example.com"), "any user can read curl's arguments with ps")
        let file = try #require(config.value)
        #expect(file.text == "url = \"https://example.com/m.json?token=s3cret\"\n")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Downloaded machine lists

    /// Each would write attacker-chosen text into nginx's config, or isn't a machine list at all.
    static let unsafeDownloads = [
        #"{"m": {"ip": "1.2.3.4; include /etc/passwd", "services": {}}}"#,
        #"{"m": {"ip": "1.2.3.4\ninclude /etc/passwd;", "services": {}}}"#,
        #"{"m": {"ip": "-oProxyCommand=x", "services": {}}}"#,
        #"{"m": {"ip": "-1.2.3.4", "services": {}}}"#,
        #"{"m": {"ip": "1.2.3.4", "services": {"web}; server { listen 1": {"local": 8080, "remote": 80}}}}"#,
        #"{"m": {"ip": "1.2.3.4", "services": {"web": {"local": "8080; include /x", "remote": 80}}}}"#,
        #"{"m": {"ip": "1.2.3.4", "services": {"web": {"local": 70000, "remote": 80}}}}"#,
        #"{"m": {"ip": "1.2.3.4", "services": {"web": {"local": 8080, "remote": null}}}}"#,
        #"{"m": {"ip": "1.2.3.4", "services": {"a": {"local": 8080, "remote": 80}, "b": {"local": 8080, "remote": 81}}}}"#,
        #"{"../m": {"ip": "1.2.3.4", "services": {}}}"#,
        #"{"m\nx": {"ip": "1.2.3.4", "services": {}}}"#,
        #"{"m": {"ip": "1.2.3.4"}}"#,
        #"{"containers": {"m": "1.2.3.4; include /etc/passwd"}}"#,
        #"{"containers": {"m\nx": "1.2.3.4"}}"#,
        #"{"containers": {"services": "1.2.3.4"}}"#,
        #"{"containers": {"m": "1.2.3.4"}, "m": {"ip": "1.2.3.5", "services": {}}}"#,
        #"{"containers": ["1.2.3.4"]}"#,
        #"{"containers": {"m": "1.2.3.4"}, "services": {"web}; server { listen 1": {"local": 8080, "remote": 80}}}"#,
        #"{"containers": {"m": "1.2.3.4"}, "services": {"web": {"local": 8080, "remote": null}}}"#,
        #"{} {}"#,
        "[]",
        "<html><body>Sign in</body></html>",
        "",
    ]

    @Test(arguments: unsafeDownloads)
    func unsafeDownloadsAreRejectedAndMachinesKept(_ download: String) async throws {
        let store = MachineStore(paths: paths)
        try store.save(MachineFile(machines: ["old": Machine(ip: "9.9.9.9", services: [:])]))
        let before = try Data(contentsOf: paths.machines)
        runner.onAny("curl", handler: curlWriting(download))

        await #expect(throws: SyncError.self) {
            try await Syncer(runner: runner).sync(SyncSettings(url: "https://example.com/m.json"), into: store)
        }
        #expect(try Data(contentsOf: paths.machines) == before)
    }

    @Test func anOversizedDownloadIsRejectedEvenWhenItIsValidJSON() async throws {
        // A server ignoring curl's cap, or scp, which has none: valid JSON padded past the limit
        let padded = String(repeating: " ", count: Syncer.maxDownloadBytes) + "{}"
        runner.onAny("scp") { _, args in
            try? Data(padded.utf8).write(to: URL(fileURLWithPath: args.last!))
            return FakeRunner.ok
        }
        await #expect(throws: SyncError.self) { try await Syncer(runner: runner).fetch(SyncSettings(host: "h")) }
    }

    @Test func aDuplicateMachineCantSmuggleAHostileCopyPastTheChecks() async throws {
        // jq (the CLI) keeps the last copy, JSONDecoder the first: whichever the app reads must be safe
        let download = #"{"m": {"ip": "1.2.3.4\nserver { listen 4444; }", "services": {}}, "m": {"ip": "10.0.0.1", "services": {}}}"#
        runner.onAny("curl", handler: curlWriting(download))
        let machines = try? await Syncer(runner: runner).fetch(SyncSettings(url: "https://example.com/m.json"))
        #expect(machines == nil || machines?.all["m"]?.ip == "10.0.0.1")
    }

    @Test func aTokenInTheSyncURLNeverReachesTheLog() async throws {
        runner.onAny("curl", handler: curlWriting(#"{"m": {"ip": "10.0.0.1", "services": {}}}"#))
        let engine = LokiEngine(paths: paths, runner: runner)
        try await engine.sync(SyncSettings(url: "https://example.com/team/machine.json?token=s3cret#frag"))

        let log = try #require(tmp.read(".loki/loki.log"))
        #expect(log.contains("Fetching machines.json from https://example.com/team/machine.json ..."))
        #expect(!log.contains("s3cret") && !log.contains("frag"))
    }

    @Test func aPasswordInARefusedSyncURLNeverReachesTheLog() async throws {
        let engine = LokiEngine(paths: paths, runner: runner)
        await #expect(throws: SyncError.self) { try await engine.sync(SyncSettings(url: "https://alice:hunter2@example.com/m.json")) }
        #expect(!(tmp.read(".loki/loki.log") ?? "").contains("hunter2"))
        #expect(runner.calls.isEmpty)
    }

    // MARK: remote.conf's header comment

    @Test func disconnectKeepsAnUncheckedIPInsideTheComment() async throws {
        // Disconnect doesn't check machine.json, so a line break in the IP must not end the comment
        try runner.scriptNginx(confDir: tmp.path("nginx"))
        try tmp.write(".loki/machine.json", #"{"m1": {"ip": "10.0.0.1\nserver { listen 2222; proxy_pass 10.9.9.9:22; } #", "services": {}}}"#)
        try MachineStore(paths: paths).setActive("m1")
        try await LokiEngine(paths: paths, runner: runner).disconnect()
        let installed = try #require(tmp.read("nginx/remote.conf"))
        #expect(installed.split(separator: "\n").count == 1, "\(installed)")
        #expect(installed.hasPrefix("# Auto-generated remote.conf for m1 (10.0.0.1 server { listen 2222"))
    }

    @Test func aRemovedMachinesHeaderStaysOneLine() async throws {
        try runner.scriptNginx(confDir: tmp.path("nginx"))
        try tmp.write(".loki/active", "gone\ninclude /etc/evil.conf;\n")
        runner.onAny("curl", handler: curlWriting(#"{"m2": {"ip": "10.0.0.2", "services": {}}}"#))
        try await LokiEngine(paths: paths, runner: runner).sync(SyncSettings(url: "https://example.com/m.json"))
        let installed = try #require(tmp.read("nginx/remote.conf"))
        #expect(installed == "# Auto-generated remote.conf: gone include /etc/evil.conf; was removed from machine.json\n")
    }

    // MARK: ~/.loki/config is shell code for the CLI

    @Test func savedSettingsCantRunCommandsWhenTheCLISourcesThem() async throws {
        let marker = tmp.path("pwned").path
        let s = SyncSettings(user: "u'; touch \(marker); '", host: "h", port: 22,
                             remotePath: "/x/$(touch \(marker))/`touch \(marker)`.json",
                             url: "https://example.com/'$(touch \(marker))'?a=1;touch \(marker)")
        try s.save(to: paths)
        let script = #". "$1"; printf '%s|%s|%s' "$LOKI_SSH_USER" "$LOKI_REMOTE_MACHINES_JSON" "$LOKI_SYNC_URL""#
        let result = await ProcessRunner().run("/bin/sh", ["-c", script, "sh", paths.config.path])
        #expect(result.output == "\(s.user)|\(s.remotePath)|\(s.url)")
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    // MARK: Update check

    @Test func theUpdateButtonOpensAFixedPageNotOneFromGitHubsAnswer() {
        // The response's html_url is never read, so a hostile one ("…/releases/../../evil") can't redirect
        let answer = Data(#"{"tag_name": "9.0.0", "html_url": "https://github.com/rajadubey/loki/releases/../../../evil/x"}"#.utf8)
        #expect(UpdateCheck.outcome(current: "2.0.1", response: answer) == .newer(version: "9.0.0"))
        #expect(UpdateCheck.releasesPage.absoluteString == "https://github.com/rajadubey/loki/releases/latest")
    }

    @Test(arguments: ["not json", #"{"tag_name": 9}"#, #"{"name": "9.0.0"}"#, #"{"tag_name": "9.0.0; rm -rf /"}"#])
    func aGarbledUpdateResponseMeansNoUpdate(_ body: String) {
        #expect(UpdateCheck.outcome(current: "2.0.1", response: Data(body.utf8)) == .upToDate)
    }
}

/// A value a `@Sendable` fake can set and the test read afterwards.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
