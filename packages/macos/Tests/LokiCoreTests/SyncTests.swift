import Foundation
import Testing
@testable import LokiCore

private let remoteJSON = #"{"build":{"ip":"10.1.0.1","services":{"web":{"local":8080,"remote":80}}}}"#

/// scp fake: writes `content` to the destination (last argument) and succeeds.
private func scpWriting(_ content: String) -> FakeRunner.Handler {
    { _, args in
        try? Data(content.utf8).write(to: URL(fileURLWithPath: args.last!))
        return FakeRunner.ok
    }
}

@Suite struct SyncSettingsTests {
    @Test func defaultsMatchTheCLI() {
        let s = SyncSettings.parse("")
        #expect(s == SyncSettings(user: "root", host: "", port: 22, remotePath: "/mnt/machines.json"))
        #expect(!s.isConfigured)
    }

    @Test func parsesAllQuotingStylesExportAndComments() {
        let text = #"""
        # loki settings
        LOKI_SSH_USER=deploy
          export   LOKI_SSH_HOST="build.example.com"   # the shared box
        LOKI_SSH_PORT='2222'
        LOKI_REMOTE_MACHINES_JSON='/srv/it'\''s "team" machines.json'
        # LOKI_SSH_USER=commented-out
        OTHER_VAR=ignored
        not an assignment
        """#
        let s = SyncSettings.parse(text)
        #expect(s == SyncSettings(user: "deploy", host: "build.example.com", port: 2222, remotePath: #"/srv/it's "team" machines.json"#))
        #expect(s.isConfigured)
    }

    @Test(arguments: [
        ("LOKI_SSH_HOST=plain", "plain"),
        ("LOKI_SSH_HOST='single quoted'", "single quoted"),
        (#"LOKI_SSH_HOST="double \"escaped\" \\ quote""#, #"double "escaped" \ quote"#),
        (#"LOKI_SSH_HOST=back\ slash"#, "back slash"),
        ("LOKI_SSH_HOST=value # comment", "value"),
        ("LOKI_SSH_HOST=value;echo hi", "value"),
        ("LOKI_SSH_HOST=two words", "two"),
        ("LOKI_SSH_HOST=mixed'quo ted'\"x y\"", "mixedquo tedx y"),
        ("LOKI_SSH_HOST='a#b'", "a#b"),
        ("LOKI_SSH_HOST=", ""),
        ("export LOKI_SSH_HOST=exported", "exported"),
    ])
    func unquotesLikeTheShell(_ line: String, _ expected: String) {
        #expect(SyncSettings.parse(line).host == expected)
    }

    @Test func portParsing() {
        #expect(SyncSettings.parse("LOKI_SSH_PORT=2200").port == 2200)
        #expect(SyncSettings.parse("LOKI_SSH_PORT=\"2201\"").port == 2201)
        #expect(SyncSettings.parse("LOKI_SSH_PORT=abc").port == 22)
        #expect(SyncSettings.parse("LOKI_SSH_PORT=").port == 22)
        #expect(SyncSettings.parse("LOKI_SSH_PORT=99999").port == 99999)  // parsed; `problems` reports it
    }

    @Test func emptyUserAndPathKeepDefaults() {
        let s = SyncSettings.parse("LOKI_SSH_USER=\nLOKI_REMOTE_MACHINES_JSON=''\nLOKI_SSH_HOST=h")
        #expect(s.user == "root")
        #expect(s.remotePath == "/mnt/machines.json")
    }

    @Test func laterAssignmentWins() {
        #expect(SyncSettings.parse("LOKI_SSH_HOST=a\nLOKI_SSH_HOST=b").host == "b")
    }

    @Test func crlfLineEndings() {
        let s = SyncSettings.parse("LOKI_SSH_USER=u\r\nLOKI_SSH_HOST='h'\r\nLOKI_SSH_PORT=2022\r\n")
        #expect(s == SyncSettings(user: "u", host: "h", port: 2022))
    }

    @Test func isPresent() {
        #expect(SyncSettings.isPresent(in: "alias ll='ls -l'\nexport LOKI_SSH_HOST=h\n"))
        #expect(SyncSettings.isPresent(in: "LOKI_SSH_PORT=22"))
        #expect(!SyncSettings.isPresent(in: "alias ll='ls -l'\n# LOKI_SSH_HOST=h\n"))
    }

    @Test func serializedFromScratch() {
        let s = SyncSettings(user: "deploy", host: "h.example.com", port: 2222, remotePath: "/mnt/machines.json")
        #expect(s.serialized() == """
        # loki settings, read by the loki app and CLI
        LOKI_SSH_USER='deploy'
        LOKI_SSH_HOST='h.example.com'
        LOKI_SSH_PORT='2222'
        LOKI_REMOTE_MACHINES_JSON='/mnt/machines.json'
        LOKI_SYNC_URL=''

        """)
    }

    @Test func serializedRoundTripsValuesWithQuotesAndSpaces() {
        let s = SyncSettings(user: "o'brien", host: "h", port: 2200, remotePath: #"/srv/it's a "team" file\x.json"#)
        let text = s.serialized()
        #expect(text.contains(#"LOKI_REMOTE_MACHINES_JSON='/srv/it'\''s a "team" file\x.json'"#))
        #expect(SyncSettings.parse(text) == s)
    }

    @Test func serializedValuesAreReadBackByARealShell() async throws {
        let s = SyncSettings(user: "u", host: "h", port: 2200, remotePath: #"/srv/it's a "team" $HOME `x` file.json"#)
        let script = s.serialized() + #"printf '%s|%s|%s|%s' "$LOKI_SSH_USER" "$LOKI_SSH_HOST" "$LOKI_SSH_PORT" "$LOKI_REMOTE_MACHINES_JSON""#
        let result = await ProcessRunner().run("/bin/sh", ["-c", script])
        #expect(result.output == #"u|h|2200|/srv/it's a "team" $HOME `x` file.json"#)
    }

    @Test func serializedPreservesOtherLinesAndReplacesKeysInPlace() {
        let existing = """
        # my settings
        FOO=bar
        LOKI_SSH_HOST=old-host
          export LOKI_SSH_PORT=1
        # LOKI_SSH_USER=commented

        BAZ="qux"
        """
        let s = SyncSettings(user: "u", host: "new-host", port: 2222, remotePath: "/p")
        #expect(s.serialized(preserving: existing + "\n") == """
        # my settings
        FOO=bar
        LOKI_SSH_HOST='new-host'
        LOKI_SSH_PORT='2222'
        # LOKI_SSH_USER=commented

        BAZ="qux"
        LOKI_SSH_USER='u'
        LOKI_REMOTE_MACHINES_JSON='/p'
        LOKI_SYNC_URL=''

        """)
        // no trailing newline in the existing file: same result
        #expect(s.serialized(preserving: existing) == s.serialized(preserving: existing + "\n"))
    }

    @Test func serializingTwiceIsStable() {
        let s = SyncSettings(user: "u", host: "h", port: 22, remotePath: "/p")
        let once = s.serialized(preserving: "X=1\n")
        #expect(s.serialized(preserving: once) == once)
    }

    @Test func urlRoundTripsAndWinsOverSSH() {
        let s = SyncSettings(host: "h", url: "https://example.com/team's/m.json?x=1#top")
        #expect(SyncSettings.parse(s.serialized()) == s)
        #expect(s.usesURL && s.isConfigured)
        #expect(s.source == "https://example.com/team's/m.json")
        #expect(SyncSettings(url: "https://example.com/m.json").isConfigured)  // no SSH host needed
        #expect(!SyncSettings(host: "h").usesURL)
        #expect(SyncSettings.isPresent(in: "export LOKI_SYNC_URL=https://example.com/m.json"))
    }

    @Test func urlProblemsNameTheFix() {
        #expect(SyncSettings(url: "http://example.com/m.json").problems == ["The URL must be a full https:// address without spaces, quotes or backslashes."])
        #expect(SyncSettings(url: "https://gist.github.com/u/abc").problems.first?.contains("Raw link") == true)
    }

    @Test func problemsForDefaults() {
        #expect(SyncSettings().problems == ["Enter the SSH host."])
    }

    @Test func validSettingsHaveNoProblems() {
        for host in ["build.example.com", "10.0.0.1", "[::1]", "fe80::1", "host-1"] {
            #expect(SyncSettings(user: "deploy_1", host: host, port: 1).problems.isEmpty)
        }
        #expect(SyncSettings(host: "h", port: 65535).problems.isEmpty)
    }

    @Test(arguments: ["-oProxyCommand=touch /tmp/x", "-p", "-", "a b", "h;rm", "h\n", "$(id)"])
    func hostThatCouldInjectOptionsIsRejected(_ host: String) {
        #expect(SyncSettings(host: host).problems == ["Host “\(host)” has characters ssh won't accept."])
    }

    @Test func userIsCheckedToo() {
        #expect(SyncSettings(user: "-oProxyCommand=x", host: "h").problems == ["User “-oProxyCommand=x” has characters ssh won't accept."])
        #expect(SyncSettings(user: "", host: "h").problems == ["Enter the SSH user."])
    }

    @Test(arguments: [0, -1, 65536])
    func badPort(_ port: Int) {
        #expect(SyncSettings(host: "h", port: port).problems == ["Port must be between 1 and 65535."])
    }

    @Test func emptyRemotePath() {
        #expect(SyncSettings(host: "h", remotePath: "").problems == ["Enter the path of machines.json on the host."])
    }

    @Test func saveAndLoad() throws {
        let tmp = try TempDir()
        let paths = LokiPaths(home: tmp.path("new/.loki"))  // folder doesn't exist yet
        #expect(SyncSettings.load(from: paths) == SyncSettings())
        try tmp.write("new/.loki/config", "# keep me\nLOKI_SSH_HOST=old\n")
        let s = SyncSettings(user: "u", host: "h", port: 2022, remotePath: "/x y.json")
        try s.save(to: paths)
        #expect(SyncSettings.load(from: paths) == s)
        #expect(tmp.read("new/.loki/config")?.hasPrefix("# keep me\nLOKI_SSH_HOST='h'\n") == true)
        withExtendedLifetime(tmp) {}
    }
}

@Suite struct SyncerTests {
    let tmp: TempDir
    let runner = FakeRunner()
    let store: MachineStore
    let settings = SyncSettings(user: "deploy", host: "build.example.com", port: 2222, remotePath: "/srv/machines.json")

    init() throws {
        tmp = try TempDir()
        store = MachineStore(paths: LokiPaths(home: tmp.path(".loki")))
    }

    private func seedOldMachines() throws -> Data {
        try store.save(["old": Machine(ip: "9.9.9.9", services: [:])])
        return try Data(contentsOf: store.paths.machines)
    }

    @Test func testConnectionUsesBatchModeAndLowercaseP() async {
        runner.on("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-p", "2222", "deploy@build.example.com",
                          "test -r '/srv/machines.json' && echo ok"], FakeRunner.ok("ok\n"))
        let result = await Syncer(runner: runner).testConnection(settings)
        #expect(result == FakeRunner.ok("ok\n"))
        #expect(runner.calls.count == 1)
    }

    @Test func testConnectionQuotesTheRemotePath() async {
        var s = settings
        s.remotePath = "/srv/it's here.json"
        _ = await Syncer(runner: runner).testConnection(s)
        #expect(runner.calls.first?.last == #"test -r '/srv/it'\''s here.json' && echo ok"#)
    }

    @Test func testConnectionWithBadSettingsRunsNothing() async {
        let result = await Syncer(runner: runner).testConnection(SyncSettings(host: "-oProxyCommand=x"))
        #expect(result.status == 2)
        #expect(result.output.contains("-oProxyCommand=x"))
        #expect(runner.calls.isEmpty)
    }

    @Test func syncDownloadsWithScpAndSaves() async throws {
        let old = try seedOldMachines()
        runner.onAny("scp", handler: scpWriting(remoteJSON))
        let machines = try await Syncer(runner: runner).sync(settings, into: store)
        #expect(machines == ["build": Machine(ip: "10.1.0.1", services: ["web": Ports(local: 8080, remote: 80)])])
        #expect(try store.load() == machines)
        #expect(try Data(contentsOf: tmp.path(".loki/machine.json.bak")) == old)

        let call = try #require(runner.calls.first)
        #expect(Array(call.prefix(8)) == ["scp", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-P", "2222",
                                          "deploy@build.example.com:/srv/machines.json"])
        #expect(call.count == 9)
        #expect(!FileManager.default.fileExists(atPath: call[8]))  // temp download cleaned up
    }

    @Test func failedScpLeavesMachinesUntouched() async throws {
        let old = try seedOldMachines()
        runner.onAny("scp") { _, _ in FakeRunner.fail("ssh: connect to host build.example.com port 2222: Connection refused\n", status: 255) }
        await #expect(throws: SyncError.fetchFailed("ssh: connect to host build.example.com port 2222: Connection refused")) {
            try await Syncer(runner: runner).sync(settings, into: store)
        }
        #expect(try Data(contentsOf: store.paths.machines) == old)
        #expect(!tmp.exists(".loki/machine.json.bak"))
    }

    @Test(arguments: ["<html>404</html>", "[]", #"{"m":{"ip":"1.2.3.4"}}"#, #"{"m":{"ip":"1.2.3.4; evil","services":{}}}"#, ""])
    func invalidDownloadIsRejectedAndOldFileKept(_ download: String) async throws {
        let old = try seedOldMachines()
        runner.onAny("scp", handler: scpWriting(download))
        do {
            try await Syncer(runner: runner).sync(settings, into: store)
            Issue.record("sync accepted \(download)")
        } catch SyncError.invalidDownload {
        } catch {
            Issue.record("expected invalidDownload, got \(error)")
        }
        #expect(try Data(contentsOf: store.paths.machines) == old)
        #expect(!tmp.exists(".loki/machine.json.bak"))
    }

    @Test func syncDownloadsAURLWithCurlAndSaves() async throws {
        let old = try seedOldMachines()
        runner.onAny("curl", handler: curlWriting(remoteJSON))
        let s = SyncSettings(host: "build.example.com", url: "https://gist.githubusercontent.com/u/abc/raw/machine.json")
        let machines = try await Syncer(runner: runner).sync(s, into: store)
        #expect(machines == ["build": Machine(ip: "10.1.0.1", services: ["web": Ports(local: 8080, remote: 80)])])
        #expect(try store.load() == machines)
        #expect(try Data(contentsOf: tmp.path(".loki/machine.json.bak")) == old)
        #expect(runner.calls(to: "scp").isEmpty)  // the URL wins over SSH

        let call = try #require(runner.calls(to: "curl").first)
        let download = try #require(call.firstIndex(of: "-o").map { call[$0 + 1] })
        #expect(!FileManager.default.fileExists(atPath: download))  // temp download cleaned up
    }

    @Test func fetchChecksADownloadWithoutSavingIt() async throws {
        runner.onAny("curl", handler: curlWriting(remoteJSON))
        let machines = try await Syncer(runner: runner).fetch(SyncSettings(url: "https://example.com/m.json"))
        #expect(machines.keys.sorted() == ["build"])
        #expect(!tmp.exists(".loki/machine.json"))
    }

    @Test func failedDownloadLeavesMachinesUntouched() async throws {
        let old = try seedOldMachines()
        runner.onAny("curl") { _, _ in FakeRunner.fail("curl: (22) The requested URL returned error: 404\n", status: 22) }
        await #expect(throws: SyncError.fetchFailed("curl: (22) The requested URL returned error: 404")) {
            try await Syncer(runner: runner).sync(SyncSettings(url: "https://example.com/m.json"), into: store)
        }
        #expect(try Data(contentsOf: store.paths.machines) == old)
        #expect(!tmp.exists(".loki/machine.json.bak"))
    }

    @Test func notConfiguredRunsNothing() async {
        await #expect(throws: SyncError.notConfigured(["Enter the SSH host."])) {
            try await Syncer(runner: runner).sync(SyncSettings(), into: store)
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func errorDescriptions() {
        #expect(SyncError.notConfigured(["A.", "B."]).errorDescription == "Sync isn't set up: A. B.")
        #expect(SyncError.fetchFailed("x").errorDescription?.hasSuffix("\nx") == true)
        #expect(SyncError.invalidDownload("why").errorDescription?.hasSuffix(" why") == true)
    }
}
