import Foundation
import Testing
@testable import LokiCore

private let machinesJSON = #"""
{
  "dev": { "ip": "10.0.0.5", "services": { "web": { "local": 8080, "remote": 80 }, "db": { "local": 5433, "remote": 5432 } } },
  "prod": { "ip": "10.0.0.9", "services": { "web": { "local": 8080, "remote": 80 } } }
}
"""#

@Suite struct EngineTests {
    let tmp: TempDir
    let runner = FakeRunner()
    let paths: LokiPaths
    let engine: LokiEngine
    var remoteConf: URL { tmp.path("nginx/remote.conf") }

    init() throws {
        tmp = try TempDir()
        paths = LokiPaths(home: tmp.path(".loki"))
        engine = LokiEngine(paths: paths, runner: runner)
        try tmp.write(".loki/machine.json", machinesJSON)
        try runner.scriptNginx(confDir: tmp.path("nginx"))
    }

    private var installed: String? { try? String(contentsOf: remoteConf, encoding: .utf8) }
    private var logText: String { tmp.read(".loki/loki.log") ?? "" }

    @Test func connectInstallsConfigAndSetsActive() async throws {
        try await engine.connect("dev")
        #expect(tmp.read(".loki/active") == "dev\n")
        let conf = try #require(installed)
        #expect(conf.hasPrefix("# Auto-generated remote.conf for dev (10.0.0.5) ["))
        #expect(conf.contains("upstream db {\n    server 10.0.0.5:5432;\n}\nserver {\n    listen 5433;\n    proxy_pass db;\n}\n"))
        #expect(conf.contains("upstream web {\n    server 10.0.0.5:80;\n}"))
        #expect(tmp.read(".loki/remote.conf") == conf)  // copy kept for inspection, like the CLI's TMP_CONF
        #expect(runner.calls.last == ["nginx", "-s", "reload"])
        #expect(logText.contains("] Attempting to connect to machine: dev\n"))
        #expect(logText.contains("] ✅ Connected to: dev\n"))
    }

    @Test func connectSwitchesMachines() async throws {
        try await engine.connect("dev")
        try await engine.connect("prod")
        #expect(engine.store.activeName() == "prod")
        #expect(installed?.contains("server 10.0.0.9:80;") == true)
        #expect(installed?.contains("10.0.0.5") == false)
    }

    @Test func failedNginxTestLeavesActiveUnchanged() async throws {
        try await engine.connect("dev")
        let before = try #require(installed)
        try runner.scriptNginx(confDir: tmp.path("nginx"), testOK: false)
        await #expect(throws: NginxError.self) { try await engine.connect("prod") }
        #expect(tmp.read(".loki/active") == "dev\n")
        #expect(installed == before)
        #expect(logText.contains("] ❌ nginx rejected the new config"))
        #expect(!logText.contains("Connected to: prod"))
    }

    @Test func failedReloadLeavesActiveUnchanged() async throws {
        runner.on("nginx", ["-s", "reload"], FakeRunner.fail("not running"))
        runner.on("pgrep", ["-f", "nginx: master"], FakeRunner.ok("1\n"))  // running, but refuses the reload: no restart
        await #expect(throws: NginxError.reloadFailed(output: "not running")) { try await engine.connect("dev") }
        #expect(!tmp.exists(".loki/active"))
    }

    @Test func nginxNotInstalledLeavesActiveUnchanged() async throws {
        try tmp.write(".loki/active", "prod\n")
        runner.on("nginx", ["-v"], FakeRunner.fail("", status: 127))
        await #expect(throws: NginxError.notInstalled) { try await engine.connect("dev") }
        #expect(tmp.read(".loki/active") == "prod\n")
    }

    @Test func connectUnknownMachine() async throws {
        await #expect(throws: EngineError.unknownMachine("nope")) { try await engine.connect("nope") }
        #expect(runner.calls.isEmpty)
        #expect(!tmp.exists(".loki/active"))
    }

    @Test func connectWithUnreadableMachineJSON() async throws {
        try tmp.write(".loki/machine.json", "{oops")
        await #expect(throws: StoreError.self) { try await engine.connect("dev") }
        #expect(runner.calls.isEmpty)
    }

    @Test func reloadRegeneratesActiveMachine() async throws {
        try await engine.connect("dev")
        try tmp.write(".loki/machine.json", #"{"dev":{"ip":"10.0.0.6","services":{"web":{"local":8080,"remote":81}}}}"#)
        try await engine.reload()
        #expect(installed?.contains("server 10.0.0.6:81;") == true)
        #expect(installed?.contains("upstream db") == false)
        #expect(engine.store.activeName() == "dev")
        #expect(logText.contains("] ✅ Reloaded NGINX with new config for dev\n"))
    }

    @Test func reloadWithoutActive() async throws {
        await #expect(throws: EngineError.noActiveMachine) { try await engine.reload() }
        #expect(runner.calls.isEmpty)
    }

    @Test func reloadWhenActiveMachineIsGone() async throws {
        try tmp.write(".loki/active", "deleted\n")
        await #expect(throws: EngineError.unknownMachine("deleted")) { try await engine.reload() }
        #expect(runner.calls.isEmpty)
    }

    @Test func disconnectWritesHeaderOnlyConfigAndClearsActive() async throws {
        try await engine.connect("dev")
        try await engine.disconnect()
        let conf = try #require(installed)
        #expect(conf.hasPrefix("# Auto-generated remote.conf for dev (10.0.0.5) ["))
        #expect(conf.hasSuffix("]\n"))
        #expect(conf.components(separatedBy: "\n").count == 2)  // one line + trailing newline
        #expect(!tmp.exists(".loki/active"))
        #expect(logText.contains("] ✅ Disconnected from dev\n"))
    }

    @Test func disconnectOfAMachineNoLongerInTheList() async throws {
        try tmp.write(".loki/active", "deleted\n")
        try await engine.disconnect()
        #expect(installed?.hasPrefix("# Auto-generated remote.conf for deleted () [") == true)
        #expect(!tmp.exists(".loki/active"))
    }

    @Test func failedDisconnectKeepsActive() async throws {
        try await engine.connect("dev")
        try runner.scriptNginx(confDir: tmp.path("nginx"), testOK: false)
        await #expect(throws: NginxError.self) { try await engine.disconnect() }
        #expect(engine.store.activeName() == "dev")
    }

    @Test func disconnectWhenNothingActiveIsANoOp() async throws {
        try await engine.disconnect()
        #expect(runner.calls.isEmpty)
        #expect(installed == nil)
        #expect(!tmp.exists(".loki/loki.log"))
    }

    // MARK: sync

    private let settings = SyncSettings(user: "deploy", host: "build", port: 22, remotePath: "/srv/machines.json")

    private func serveOverScp(_ json: String) {
        runner.onAny("scp") { _, args in
            try? Data(json.utf8).write(to: URL(fileURLWithPath: args.last!))
            return FakeRunner.ok
        }
    }

    @Test func syncReloadsWhenActiveStillExists() async throws {
        try await engine.connect("dev")
        serveOverScp(#"{"dev":{"ip":"10.9.9.9","services":{"web":{"local":8080,"remote":80}}},"new":{"ip":"1.1.1.1","services":{}}}"#)
        try await engine.sync(settings)
        #expect(try engine.store.load().keys.sorted() == ["dev", "new"])
        #expect(installed?.contains("server 10.9.9.9:80;") == true)
        #expect(engine.store.activeName() == "dev")
        #expect(logText.contains("] Fetching machines.json from deploy@build:/srv/machines.json ...\n"))
        #expect(logText.contains("] ✅ Updated local machines.json (2 machines)\n"))
        #expect(logText.contains("] ✅ Reloaded NGINX with new config for dev\n"))
    }

    @Test func syncDisconnectsWhenActiveWasRemoved() async throws {
        try await engine.connect("dev")
        serveOverScp(#"{"prod":{"ip":"10.0.0.9","services":{}}}"#)
        try await engine.sync(settings)
        #expect(installed == "# Auto-generated remote.conf: dev was removed from machine.json\n")
        #expect(!tmp.exists(".loki/active"))
        #expect(logText.contains("] Active machine dev is no longer in machine.json, disconnecting\n"))
    }

    @Test func syncWithNothingActiveDoesntTouchNginx() async throws {
        serveOverScp(#"{"prod":{"ip":"10.0.0.9","services":{}}}"#)
        try await engine.sync(settings)
        #expect(runner.calls.map(\.first) == ["scp"])
        #expect(installed == nil)
    }

    @Test func failedSyncChangesNothing() async throws {
        try await engine.connect("dev")
        let before = installed
        runner.onAny("scp") { _, _ in FakeRunner.fail("Permission denied (publickey).", status: 255) }
        await #expect(throws: SyncError.fetchFailed("Permission denied (publickey).")) { try await engine.sync(settings) }
        #expect(try engine.store.load().keys.sorted() == ["dev", "prod"])
        #expect(installed == before)
        #expect(engine.store.activeName() == "dev")
        #expect(!logText.contains("Updated local machines.json"))
    }

    @Test func logLinesUseTheCLIFormat() async throws {
        try await engine.connect("dev")
        let lines = logText.split(separator: "\n")
        #expect(lines.count == 2)
        for line in lines {
            #expect(line.wholeMatch(of: /\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] .+/) != nil)
        }
    }
}
