import Foundation
import Testing
@testable import LokiCore

private let newConfig = "# Auto-generated remote.conf for dev (1.2.3.4) [2024-01-01 00:00:00]\n\nupstream web {\n    server 1.2.3.4:80;\n}\nserver {\n    listen 8080;\n    proxy_pass web;\n}\n"

/// Captures what remote.conf held when `nginx -t` ran.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var get: String? { lock.withLock { value } }
    func set(_ v: String?) { lock.withLock { value = v } }
}

@Suite struct NginxControllerTests {
    let tmp: TempDir
    let runner = FakeRunner()
    var confDir: URL { tmp.path("etc/nginx") }
    var remoteConf: URL { confDir.appending(path: "remote.conf") }

    init() throws { tmp = try TempDir() }

    /// An nginx that never looks at the real Homebrew folders.
    private var nginx: Nginx {
        var n = Nginx(runner: runner)
        n.fallbackConfDirectories = []
        return n
    }

    // MARK: Output parsing

    @Test func configPathFromSuccessfulTestPrintedTwice() {
        let out = """
        nginx: the configuration file /opt/homebrew/etc/nginx/nginx.conf syntax is ok
        nginx: configuration file /opt/homebrew/etc/nginx/nginx.conf test is successful
        """
        #expect(Nginx.configPath(fromTestOutput: out) == "/opt/homebrew/etc/nginx/nginx.conf")
    }

    @Test func configPathFromFailedTest() {
        let permission = """
        nginx: [alert] could not open error log file: open() "/opt/homebrew/var/log/nginx/error.log" failed (13: Permission denied)
        nginx: the configuration file /usr/local/etc/nginx/nginx.conf syntax is ok
        2024/01/01 00:00:00 [emerg] 123#0: open() "/usr/local/var/run/nginx.pid" failed (13: Permission denied)
        nginx: configuration file /usr/local/etc/nginx/nginx.conf test failed
        """
        #expect(Nginx.configPath(fromTestOutput: permission) == "/usr/local/etc/nginx/nginx.conf")
        let syntax = """
        nginx: [emerg] unexpected "}" in /etc/nginx/remote.conf:3
        nginx: configuration file /etc/nginx/nginx.conf test failed
        """
        #expect(Nginx.configPath(fromTestOutput: syntax) == "/etc/nginx/nginx.conf")
    }

    @Test func configPathMissing() {
        #expect(Nginx.configPath(fromTestOutput: "") == nil)
        #expect(Nginx.configPath(fromTestOutput: "env: nginx: No such file or directory") == nil)
        #expect(Nginx.configPath(fromTestOutput: "nginx: [emerg] unknown directive \"x\" in /etc/nginx/nginx.conf:1") == nil)
    }

    @Test func pidPathFromVersionOutput() {
        let out = """
        nginx version: nginx/1.27.0
        built by clang 15.0.0 (clang-1500.3.9.4)
        built with OpenSSL 3.3.0 9 Apr 2024
        TLS SNI support enabled
        configure arguments: --prefix=/opt/homebrew/Cellar/nginx/1.27.0 --sbin-path=/opt/homebrew/Cellar/nginx/1.27.0/bin/nginx --conf-path=/opt/homebrew/etc/nginx/nginx.conf --pid-path=/opt/homebrew/var/run/nginx.pid --lock-path=/opt/homebrew/var/run/nginx.lock
        """
        #expect(Nginx.pidPath(fromVersionOutput: out) == "/opt/homebrew/var/run/nginx.pid")
        #expect(Nginx.pidPath(fromVersionOutput: "nginx version: nginx/1.27.0\nconfigure arguments: --prefix=/x") == nil)
    }

    // MARK: Queries

    @Test func simpleQueriesRunTheRightCommands() async {
        runner.on("nginx", ["-v"], FakeRunner.ok("nginx version: nginx/1.27.0"))
        runner.on("pgrep", ["-f", "nginx: master"], FakeRunner.ok("123\n"))
        runner.on("nginx", ["-V"], FakeRunner.ok("configure arguments: --pid-path=/x/nginx.pid --lock-path=/x/l"))
        #expect(await nginx.isInstalled())
        #expect(await nginx.isRunning())
        #expect(await !nginx.runsAsRoot())
        #expect(await nginx.pidFilePath() == "/x/nginx.pid")
        _ = await nginx.reload()
        #expect(runner.calls == [
            ["nginx", "-v"], ["pgrep", "-f", "nginx: master"], ["pgrep", "-u", "0", "-f", "nginx: master"],
            ["nginx", "-V"], ["nginx", "-s", "reload"],
        ])
    }

    @Test func configFileFromTestOutput() async throws {
        let conf = try runner.scriptNginx(confDir: confDir)
        #expect(await nginx.configFile()?.path == conf.path)
        #expect(await nginx.configDirectory()?.path == confDir.path)
    }

    @Test func configFileIgnoresAPrintedPathThatDoesntExist() async throws {
        runner.on("nginx", ["-t"], FakeRunner.ok(FakeRunner.nginxTestOutput(tmp.path("missing/nginx.conf"))))
        #expect(await nginx.configFile() == nil)
    }

    @Test func configFileFallsBackToKnownDirectories() async throws {
        runner.on("nginx", ["-t"], FakeRunner.fail("nginx: [emerg] something odd"))
        let conf = try tmp.write("fallback/nginx.conf", "events {}\n")
        var n = Nginx(runner: runner)
        n.fallbackConfDirectories = [tmp.path("nope").path, tmp.path("fallback").path]
        #expect(await n.configFile()?.path == conf.path)
    }

    // MARK: install

    @Test func installWritesTestsThenReloads() async throws {
        try runner.scriptNginx(confDir: confDir)
        let seen = Box()
        let remote = remoteConf
        runner.on("nginx", ["-t"]) { _, _ in
            seen.set(try? String(contentsOf: remote, encoding: .utf8))
            return FakeRunner.ok(FakeRunner.nginxTestOutput(remote.deletingLastPathComponent().appending(path: "nginx.conf")))
        }
        try await nginx.install(config: newConfig)
        #expect(try String(contentsOf: remoteConf, encoding: .utf8) == newConfig)
        #expect(seen.get == newConfig)  // nginx tested the new file
        #expect(Array(runner.calls.suffix(2)) == [["nginx", "-t"], ["nginx", "-s", "reload"]])
        #expect(runner.calls.first == ["nginx", "-v"])
        #expect(runner.calls.contains(["pgrep", "-u", "0", "-f", "nginx: master"]))
    }

    @Test func failedTestRestoresPreviousContentExactly() async throws {
        try runner.scriptNginx(confDir: confDir, testOK: false)
        let previous = "# previous ✅ config\nupstream x {\n    server 9.9.9.9:1;\n}"  // no trailing newline
        try Data(previous.utf8).write(to: remoteConf)
        await #expect(throws: NginxError.testFailed(output: FakeRunner.nginxTestOutput(confDir.appending(path: "nginx.conf"), ok: false)
            .trimmingCharacters(in: .whitespacesAndNewlines))) {
            try await nginx.install(config: newConfig)
        }
        #expect(try Data(contentsOf: remoteConf) == Data(previous.utf8))
        #expect(!runner.calls.contains(["nginx", "-s", "reload"]))
    }

    @Test func failedTestWithoutPreviousFileLeavesItEmpty() async throws {
        try runner.scriptNginx(confDir: confDir, testOK: false)
        await #expect(throws: NginxError.self) { try await nginx.install(config: newConfig) }
        // nginx.conf includes remote.conf by path, so it must stay (empty) rather than disappear
        #expect(try Data(contentsOf: remoteConf).isEmpty)
    }

    @Test func failedReloadKeepsNewConfig() async throws {
        try runner.scriptNginx(confDir: confDir)
        runner.on("nginx", ["-s", "reload"], FakeRunner.fail("nginx: [error] open() \"/opt/homebrew/var/run/nginx.pid\" failed (2: No such file or directory)\n"))
        runner.on("pgrep", ["-f", "nginx: master"], FakeRunner.ok("1\n"))  // running, but refuses the reload: no restart
        await #expect(throws: NginxError.reloadFailed(output: "nginx: [error] open() \"/opt/homebrew/var/run/nginx.pid\" failed (2: No such file or directory)")) {
            try await nginx.install(config: newConfig)
        }
        #expect(try String(contentsOf: remoteConf, encoding: .utf8) == newConfig)
    }

    @Test func notInstalled() async throws {
        await #expect(throws: NginxError.notInstalled) { try await nginx.install(config: newConfig) }
        #expect(runner.calls == [["nginx", "-v"]])
    }

    @Test func noConfigDirectory() async throws {
        runner.on("nginx", ["-v"], FakeRunner.ok)
        runner.on("nginx", ["-t"], FakeRunner.fail("nginx: [emerg] no config"))
        await #expect(throws: NginxError.confDirectoryNotFound) { try await nginx.install(config: newConfig) }
    }

    @Test func rootNginxNeedsRoot() async throws {
        try runner.scriptNginx(confDir: confDir)
        runner.on("pgrep", ["-u", "0", "-f", "nginx: master"], FakeRunner.ok("1\n"))
        await #expect(throws: NginxError.needsRoot(directory: confDir.path)) { try await nginx.install(config: newConfig) }
        #expect(!FileManager.default.fileExists(atPath: remoteConf.path))
        #expect(!runner.calls.contains(["nginx", "-s", "reload"]))
    }

    @Test func unwritableDirectoryNeedsRoot() async throws {
        try runner.scriptNginx(confDir: confDir)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: confDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: confDir.path) }
        await #expect(throws: NginxError.needsRoot(directory: confDir.path)) { try await nginx.install(config: newConfig) }
        #expect(!FileManager.default.fileExists(atPath: remoteConf.path))
    }

    @Test func errorMessagesAreHelpful() {
        #expect(NginxError.notInstalled.errorDescription?.contains("brew install nginx") == true)
        #expect(NginxError.needsRoot(directory: "/d").errorDescription?.contains("/d") == true)
        #expect(NginxError.testFailed(output: "boom").errorDescription?.hasSuffix("\nboom") == true)
        #expect(NginxError.reloadFailed(output: "boom").errorDescription?.hasSuffix("\nboom") == true)
        #expect(NginxError.writeFailed("disk").errorDescription == "Couldn't write remote.conf: disk")
    }
}
