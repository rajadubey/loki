import Foundation
import Testing
@testable import LokiCore

/// `Nginx.reloadOrStart`: the Swift port of main's reload fix (4f07f29), with the same rules as loki.sh's reload_nginx.
@Suite struct ReloadFallbackTests {
    let runner = FakeRunner()
    var nginx: Nginx {
        var n = Nginx(runner: runner)
        n.startAttempts = 3
        n.startRetryDelay = .zero
        return n
    }

    static let staleReload = FakeRunner.fail("nginx: [error] invalid PID number \"\" in \"/x/nginx.pid\"")
    static let addressInUse = FakeRunner.fail("nginx: [emerg] bind() to 0.0.0.0:8080 failed (48: Address already in use)")

    private func starts() -> Int { runner.calls(to: "nginx").filter { $0 == ["nginx"] }.count }

    @Test func reloadThatWorksDoesNothingElse() async {
        runner.on("nginx", ["-s", "reload"], FakeRunner.ok(""))
        #expect(await nginx.reloadOrStart().succeeded)
        #expect(runner.calls(to: "pkill").isEmpty)
        #expect(starts() == 0)
    }

    @Test func runningNginxThatRefusesTheReloadIsLeftAlone() async {
        runner.on("nginx", ["-s", "reload"], Self.staleReload)
        runner.on("pgrep", ["-f", "nginx: master"], FakeRunner.ok("1\n"))
        let r = await nginx.reloadOrStart()
        #expect(!r.succeeded)
        #expect(r.output.contains("invalid PID"))
        #expect(runner.calls(to: "pkill").isEmpty)
        #expect(starts() == 0)
    }

    @Test func noMasterStopsStragglersAndStartsNginx() async {
        runner.on("nginx", ["-s", "reload"], Self.staleReload)
        runner.on("nginx", [], FakeRunner.ok(""))
        #expect(await nginx.reloadOrStart().succeeded)
        #expect(runner.calls(to: "pkill") == [["pkill", "-f", "nginx: (master|worker)"]])
        #expect(starts() == 1)
    }

    @Test func retriesWhileAddressInUseThenSucceeds() async {
        runner.on("nginx", ["-s", "reload"], Self.staleReload)
        runner.on("nginx", [], Self.addressInUse, FakeRunner.ok(""))
        #expect(await nginx.reloadOrStart().succeeded)
        #expect(starts() == 2)
    }

    @Test func givesUpAfterStartAttempts() async {
        runner.on("nginx", ["-s", "reload"], Self.staleReload)
        runner.on("nginx", [], Self.addressInUse)
        let r = await nginx.reloadOrStart()
        #expect(!r.succeeded)
        #expect(r.output.contains("Address already in use"))
        #expect(starts() == 3)
    }

    @Test func otherStartErrorsAreNotRetried() async {
        runner.on("nginx", ["-s", "reload"], Self.staleReload)
        runner.on("nginx", [], FakeRunner.fail("nginx: [emerg] unknown directive \"x\""))
        let r = await nginx.reloadOrStart()
        #expect(r.output.contains("unknown directive"))
        #expect(starts() == 1)
    }

    @Test func respawnedNginxCountsAsSuccess() async {
        // brew services / launchd brought it back between our checks: start fails, but a reload now works
        runner.on("nginx", ["-s", "reload"], Self.staleReload, FakeRunner.ok(""))
        runner.on("pgrep", ["-f", "nginx: master"], FakeRunner.fail(), FakeRunner.ok("1\n"))
        runner.on("nginx", [], Self.addressInUse)
        #expect(await nginx.reloadOrStart().succeeded)
        #expect(starts() == 1)
    }
}
