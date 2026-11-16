import Foundation
import Testing
@testable import LokiCore

private let configuredConf = "events {}\nstream {\n    include remote.conf;\n}\n"
private let plainConf = "worker_processes 1;\nevents {}\nhttp {\n    server { listen 8080; }\n}\n"

@Suite struct SetupTests {
    let tmp: TempDir
    let runner = FakeRunner()
    let paths: LokiPaths
    let setup: SetupAssistant
    var confDir: URL { tmp.path("nginx") }
    var nginxConf: URL { confDir.appending(path: "nginx.conf") }

    init() throws {
        tmp = try TempDir()
        paths = LokiPaths(home: tmp.path(".loki"))
        setup = SetupAssistant(paths: paths, runner: runner)
    }

    /// Installed nginx running as the user, with the given nginx.conf.
    private func healthyNginx(_ conf: String = configuredConf) throws {
        try runner.scriptNginx(confDir: confDir, nginxConf: conf)
        runner.on("pgrep", ["-f", "nginx: master"], FakeRunner.ok("123\n"))
        runner.on("nginx", ["-V"], FakeRunner.ok("configure arguments: --pid-path=\(tmp.path("run/nginx.pid").path)"))
    }

    private func check(_ checks: [SetupCheck], _ id: SetupItem) throws -> SetupCheck {
        try #require(checks.first { $0.id == id })
    }

    // MARK: inspect

    @Test func everythingOK() async throws {
        try healthyNginx()
        try tmp.write(".loki/machine.json", #"{"a":{"ip":"1.1.1.1","services":{}},"b":{"ip":"2.2.2.2","services":{}}}"#)
        try tmp.write(".loki/config", "LOKI_SSH_USER=deploy\nLOKI_SSH_HOST=build\n")
        let checks = await setup.inspect()
        #expect(checks.map(\.id) == SetupItem.allCases)
        #expect(checks.allSatisfy { $0.state == .ok && $0.fix == nil })
        #expect(try check(checks, .configWritable).detail == confDir.path)
        #expect(try check(checks, .machines).title == "2 machines")
        #expect(try check(checks, .sync).title == "Sync from deploy@build")
    }

    @Test func notInstalled() async throws {
        let checks = await setup.inspect()
        #expect(checks.map(\.id) == [.nginxInstalled, .machines, .sync])
        #expect(checks[0].state == .failed)
        #expect(checks[0].fix == .installNginx)
        #expect(runner.calls == [["nginx", "-v"]])
    }

    @Test func rootNginx() async throws {
        try healthyNginx()
        runner.on("pgrep", ["-u", "0", "-f", "nginx: master"], FakeRunner.ok("1\n"))
        let running = try check(await setup.inspect(), .nginxRunning)
        #expect(running.state == .failed)
        #expect(running.fix == .stopRootNginx(pidPath: tmp.path("run/nginx.pid").path))
        #expect(running.fix?.needsAdmin == true)
    }

    @Test func rootNginxWithoutKnownPidPath() async throws {
        try healthyNginx()
        runner.on("pgrep", ["-u", "0", "-f", "nginx: master"], FakeRunner.ok("1\n"))
        runner.on("nginx", ["-V"], FakeRunner.ok("configure arguments: --prefix=/x"))
        #expect(await setup.runningCheck().fix == .stopRootNginx(pidPath: nil))
    }

    @Test func notRunningWithStaleRootOwnedPidFile() async throws {
        try healthyNginx()
        runner.on("pgrep", ["-f", "nginx: master"], FakeRunner.fail())
        // /bin/sh stands in for a root-owned pid file: it is owned by root on every Mac, and inspect only reads it.
        runner.on("nginx", ["-V"], FakeRunner.ok("configure arguments: --pid-path=/bin/sh"))
        let running = await setup.runningCheck()
        #expect(running.state == .failed)
        #expect(running.fix == .removeStalePidFileAndStart(path: "/bin/sh"))
        #expect(running.detail.contains("/bin/sh"))
    }

    @Test func notRunningWithOwnPidFile() async throws {
        try healthyNginx()
        try tmp.write("run/nginx.pid", "123\n")
        runner.on("pgrep", ["-f", "nginx: master"], FakeRunner.fail())
        let running = await setup.runningCheck()
        #expect(running.state == .failed)
        #expect(running.fix == .startNginx)
    }

    @Test func notRunningWithoutPidPath() async throws {
        runner.on("nginx", ["-V"], FakeRunner.fail())
        #expect(await setup.runningCheck().fix == .startNginx)
    }

    @Test func runningAsUser() async throws {
        try healthyNginx()
        let running = await setup.runningCheck()
        #expect(running.state == .ok)
        #expect(running.fix == nil)
    }

    @Test func ownedByRoot() throws {
        #expect(SetupAssistant.ownedByRoot("/bin/sh"))
        #expect(!SetupAssistant.ownedByRoot(try tmp.write("mine", "x").path))
        #expect(!SetupAssistant.ownedByRoot(tmp.path("missing").path))
    }

    @Test func unwritableConfigFolder() async throws {
        try healthyNginx()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: confDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: confDir.path) }
        let writable = try check(await setup.inspect(), .configWritable)
        #expect(writable.state == .failed)
        #expect(writable.fix == .takeOwnership(directory: confDir.path))
    }

    @Test func configNotFound() {
        #expect(setup.writableCheck(nil).state == .failed)
        #expect(setup.writableCheck(nil).fix == nil)
        #expect(setup.streamCheck(nil).state == .failed)
        #expect(setup.streamCheck(tmp.path("missing/nginx.conf")).state == .failed)
    }

    @Test func streamIncludeMissingThenFixed() async throws {
        try healthyNginx(plainConf)
        let stream = try check(await setup.inspect(), .streamInclude)
        #expect(stream.state == .failed)
        #expect(stream.fix == .addStreamInclude(nginxConf: nginxConf.path))

        try await setup.apply(.addStreamInclude(nginxConf: nginxConf.path))
        let remote = confDir.appending(path: "remote.conf").path
        #expect(tmp.read("nginx/nginx.conf") == StreamInclude.adding(to: plainConf, includePath: remote))
        #expect(tmp.read("nginx/nginx.conf")?.contains("include \(remote);") == true)
        #expect(tmp.read("nginx/nginx.conf.loki-backup") == plainConf)
        #expect(tmp.read("nginx/remote.conf") == "# Managed by loki\n")  // so nginx -t doesn't fail on a missing include
        #expect(runner.calls.suffix(3) == [["nginx", "-t"], ["pgrep", "-f", "nginx: master"], ["nginx", "-s", "reload"]])
        #expect(try check(await setup.inspect(), .streamInclude).state == .ok)
    }

    @Test func addingIncludeKeepsExistingRemoteConfAndSkipsReloadWhenStopped() async throws {
        try healthyNginx(plainConf)
        runner.on("pgrep", ["-f", "nginx: master"], FakeRunner.fail())
        try tmp.write("nginx/remote.conf", "# live config\n")
        try await setup.apply(.addStreamInclude(nginxConf: nginxConf.path))
        #expect(tmp.read("nginx/remote.conf") == "# live config\n")
        #expect(!runner.calls.contains(["nginx", "-s", "reload"]))
    }

    @Test func failedTestAfterAddingIncludeRestoresNginxConf() async throws {
        try runner.scriptNginx(confDir: confDir, testOK: false, nginxConf: plainConf)
        do {
            try await setup.apply(.addStreamInclude(nginxConf: nginxConf.path))
            Issue.record("expected an error")
        } catch let error as SetupError {
            #expect(error.message.hasPrefix("nginx rejected the change, so nginx.conf was restored.\n"))
            #expect(error.message.contains("test failed"))
        }
        #expect(tmp.read("nginx/nginx.conf") == plainConf)
        #expect(tmp.read("nginx/nginx.conf.loki-backup") == plainConf)
        #expect(!runner.calls.contains(["nginx", "-s", "reload"]))
    }

    @Test func addingIncludeToMissingFileThrows() async {
        await #expect(throws: (any Error).self) { try await setup.apply(.addStreamInclude(nginxConf: tmp.path("nope/nginx.conf").path)) }
    }

    @Test func machinesEmpty() {
        let c = setup.machinesCheck()
        #expect(c.state == .warning)
        #expect(c.fix == .openMachines)
    }

    @Test func machinesInvalid() throws {
        try tmp.write(".loki/machine.json", #"{"m":{"ip":"1.2.3.4;","services":{}}}"#)
        let c = setup.machinesCheck()
        #expect(c.state == .warning)
        #expect(c.title == "machine.json has 1 problem")
        #expect(c.detail == ValidationIssue.invalidIP(machine: "m", ip: "1.2.3.4;").description)
        #expect(c.fix == .openMachines)

        try tmp.write(".loki/machine.json", #"{"m":{"ip":"","services":{"a b":{"local":1,"remote":1}}}}"#)
        #expect(setup.machinesCheck().title == "machine.json has 2 problems")
    }

    @Test func machinesUnreadable() throws {
        try tmp.write(".loki/machine.json", "{")
        let c = setup.machinesCheck()
        #expect(c.state == .failed)
        #expect(c.fix == .openMachines)
        #expect(c.detail.contains("not valid JSON"))
    }

    @Test func machinesOK() throws {
        try tmp.write(".loki/machine.json", #"{"m":{"ip":"1.2.3.4","services":{}}}"#)
        let c = setup.machinesCheck()
        #expect(c.state == .ok)
        #expect(c.title == "1 machine")
        #expect(c.detail == paths.machines.path)
    }

    @Test func syncNotConfigured() {
        let c = setup.syncCheck()
        #expect(c.state == .warning)
        #expect(c.fix == .openSync)
    }

    @Test func syncConfigured() throws {
        try tmp.write(".loki/config", "export LOKI_SSH_HOST='build'\nLOKI_REMOTE_MACHINES_JSON=/srv/m.json\n")
        let c = setup.syncCheck()
        #expect(c.state == .ok)
        #expect(c.title == "Sync from root@build")
        #expect(c.detail == "/srv/m.json")
    }

    // MARK: apply

    @Test func startNginxRestartsTheBrewService() async throws {
        runner.on("brew", ["services", "restart", "nginx"], FakeRunner.ok)
        try await setup.apply(.startNginx)
        #expect(runner.calls == [["brew", "services", "restart", "nginx"]])
    }

    @Test func startNginxFailureCarriesOutput() async {
        runner.on("brew", ["services", "restart", "nginx"], FakeRunner.fail("Error: Failure while executing\n"))
        await #expect(throws: SetupError(message: "brew services couldn't start nginx:\nError: Failure while executing")) {
            try await setup.apply(.startNginx)
        }
        runner.on("brew", ["services", "restart", "nginx"], FakeRunner.fail(""))
        await #expect(throws: SetupError(message: "brew services couldn't start nginx")) { try await setup.apply(.startNginx) }
    }

    @Test func installNginx() async throws {
        runner.on("brew", ["install", "nginx"], FakeRunner.ok)
        try await setup.apply(.installNginx)
        #expect(runner.calls == [["brew", "install", "nginx"]])
    }

    @Test func takeOwnershipGoesThroughOsascriptWithEscapedQuotes() async throws {
        runner.on("/usr/bin/osascript", ["-e", #"do shell script "chown -R '\#(NSUserName())' '/opt/my \"nginx\" \\dir'" with administrator privileges"#], FakeRunner.ok)
        try await setup.apply(.takeOwnership(directory: #"/opt/my "nginx" \dir"#))
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.first == "/usr/bin/osascript")
    }

    @Test func removeStalePidFileThenStart() async throws {
        runner.on("/usr/bin/osascript", ["-e", #"do shell script "rm -f '/opt/homebrew/var/run/nginx.pid'" with administrator privileges"#], FakeRunner.ok)
        runner.on("brew", ["services", "restart", "nginx"], FakeRunner.ok)
        try await setup.apply(.removeStalePidFileAndStart(path: "/opt/homebrew/var/run/nginx.pid"))
        #expect(runner.calls.map(\.first) == ["/usr/bin/osascript", "brew"])
    }

    @Test func cancelledPasswordPromptSaysCancelledAndStops() async {
        runner.onAny("/usr/bin/osascript") { _, _ in FakeRunner.fail("0:120: execution error: User canceled. (-128)\n") }
        await #expect(throws: SetupError(message: "Cancelled.")) {
            try await setup.apply(.removeStalePidFileAndStart(path: "/x/nginx.pid"))
        }
        #expect(runner.calls.map(\.first) == ["/usr/bin/osascript"])  // brew never ran
    }

    @Test func adminFailureCarriesOutput() async {
        runner.onAny("/usr/bin/osascript") { _, _ in FakeRunner.fail("chown: /x: Operation not permitted") }
        await #expect(throws: SetupError(message: "Couldn't change the owner of /x:\nchown: /x: Operation not permitted")) {
            try await setup.apply(.takeOwnership(directory: "/x"))
        }
    }

    @Test func stopRootNginxStopsThenStartsAsUser() async throws {
        runner.onAny("/usr/bin/osascript") { _, _ in FakeRunner.ok }
        runner.on("brew", ["services", "restart", "nginx"], FakeRunner.ok)
        try await setup.apply(.stopRootNginx(pidPath: "/opt/homebrew/var/run/nginx.pid"))
        let script = try #require(runner.calls.first?.last)
        #expect(script.hasPrefix(#"do shell script "PATH='"#))
        #expect(script.hasSuffix(#"" with administrator privileges"#))
        #expect(script.contains("launchctl bootout system/homebrew.mxcl.nginx"))
        #expect(script.contains("launchctl bootout system/sh.brew.nginx"))
        // unloading alone brings root nginx back at the next boot
        #expect(script.contains("rm -f /Library/LaunchDaemons/homebrew.mxcl.nginx.plist /Library/LaunchDaemons/sh.brew.nginx.plist"))
        #expect(script.contains("nginx -s stop"))
        #expect(script.contains("; rm -f '/opt/homebrew/var/run/nginx.pid'"))
        #expect(runner.calls.last == ["brew", "services", "restart", "nginx"])

        try await setup.apply(.stopRootNginx(pidPath: nil))
        #expect(runner.calls[2].last?.hasSuffix(#"sleep 1" with administrator privileges"#) == true)  // no pid file to remove
    }

    @Test func navigationFixesRunNothing() async throws {
        try await setup.apply(.openMachines)
        try await setup.apply(.openSync)
        #expect(runner.calls.isEmpty)
    }

    @Test func fixLabelsAndAdminFlags() {
        let admin: [SetupFix] = [.removeStalePidFileAndStart(path: "/p"), .stopRootNginx(pidPath: nil), .takeOwnership(directory: "/d")]
        let plain: [SetupFix] = [.installNginx, .startNginx, .addStreamInclude(nginxConf: "/c"), .openMachines, .openSync]
        #expect(admin.allSatisfy { $0.needsAdmin })
        #expect(!plain.contains { $0.needsAdmin })
        #expect(Set((admin + plain).map(\.label)).count == 8)
    }
}

@Suite struct CommandsTests {
    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(shellQuote("plain") == "'plain'")
        #expect(shellQuote("it's") == #"'it'\''s'"#)
        #expect(shellQuote("") == "''")
        #expect(shellQuote(#"$HOME `x` "y" \z"#) == #"'$HOME `x` "y" \z'"#)
    }

    @Test func shellQuoteSurvivesARealShell() async {
        let nasty = #"a'b "c" $HOME `id` \n; rm -rf x"#
        let result = await ProcessRunner().run("/bin/sh", ["-c", "printf %s \(shellQuote(nasty))"])
        #expect(result == CommandResult(status: 0, output: nasty))
    }

    @Test func appleScriptWrapper() {
        #expect(AdminCommand.appleScript(for: "rm -f '/x'") == #"do shell script "rm -f '/x'" with administrator privileges"#)
        #expect(AdminCommand.appleScript(for: #"echo "hi" \ there"#) == #"do shell script "echo \"hi\" \\ there" with administrator privileges"#)
    }

    @Test func adminCommandRunsOsascript() async {
        let runner = FakeRunner()
        _ = await AdminCommand(runner: runner).run("true")
        #expect(runner.calls == [["/usr/bin/osascript", "-e", #"do shell script "true" with administrator privileges"#]])
    }

    @Test func processRunnerCombinesOutputAndStatus() async {
        let result = await ProcessRunner().run("sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.status == 3)
        #expect(!result.succeeded)
        #expect(result.output.contains("out\n"))
        #expect(result.output.contains("err\n"))
    }

    @Test func processRunnerMissingCommand() async {
        let result = await ProcessRunner().run("loki-no-such-command-\(UUID().uuidString)", [])
        #expect(!result.succeeded)
    }

    @Test func processRunnerUsesItsPathAndEnvironment() async {
        let result = await ProcessRunner(path: "/usr/bin:/bin", environment: ["LOKI_TEST": "v"]).run("sh", ["-c", "printf '%s|%s' \"$PATH\" \"$LOKI_TEST\""])
        #expect(result.output == "/usr/bin:/bin|v")
    }

    @Test func processRunnerNeverWaitsForInput() async {
        let result = await ProcessRunner().run("cat", [])
        #expect(result == CommandResult(status: 0, output: ""))
    }
}
