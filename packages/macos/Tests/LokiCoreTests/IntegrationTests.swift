import Foundation
import Testing
@testable import LokiCore

private let machinesJSON = """
{"dev": {"ip": "10.0.0.5", "services": {"web": {"local": 8080, "remote": 80}, "db": {"local": 5432, "remote": 5432}}},
 "prod": {"ip": "10.0.0.9", "services": {"web": {"local": 8081, "remote": 80}}}}
"""

/// The engine end to end: real ProcessRunner, fake nginx/pgrep/scp from ParitySandbox (see ParityTests.swift).
struct IntegrationTests {
    private func expected(_ box: ParitySandbox, _ name: String, includeServices: Bool = true) throws -> String? {
        let machine = try #require(try box.engine.store.load()[name])
        return ParitySandbox.normalized(NginxConfig.render(machineName: name, machine: machine, includeServices: includeServices))
    }

    @Test func connectSwitchDisconnect() async throws {
        let box = try ParitySandbox(machines: machinesJSON)
        let engine = box.engine

        try await engine.connect("dev")
        #expect(engine.store.activeName() == "dev")
        #expect(ParitySandbox.normalized(box.installed) == (try expected(box, "dev")))
        #expect(box.installed == ParitySandbox.read(box.paths.generatedConf))
        #expect(box.calls("nginx").suffix(2) == ["-t", "-s reload"])

        try await engine.connect("prod")
        #expect(engine.store.activeName() == "prod")
        #expect(ParitySandbox.normalized(box.installed) == (try expected(box, "prod")))

        try await engine.disconnect()
        #expect(engine.store.activeName() == nil)
        #expect(ParitySandbox.normalized(box.installed) == (try expected(box, "prod", includeServices: false)))
        #expect(box.calls("nginx").filter { $0 == "-s reload" }.count == 3)

        // Disconnecting again is a no-op.
        let calls = box.calls("nginx").count
        try await engine.disconnect()
        #expect(box.calls("nginx").count == calls)

        let log = engine.log.tail().joined(separator: "\n")
        #expect(log.contains("✅ Connected to: dev"))
        #expect(log.contains("✅ Connected to: prod"))
        #expect(log.contains("✅ Disconnected from prod"))
    }

    @Test func rejectedConfigKeepsThePreviousRemoteConfAndActive() async throws {
        let box = try ParitySandbox(machines: machinesJSON)
        try await box.engine.connect("dev")
        let before = box.installed
        box.mark("fail-test")

        await #expect {
            try await box.engine.connect("prod")
        } throws: { error in
            guard case NginxError.testFailed(let output) = error else { return false }
            return output.contains("test failed")
        }
        #expect(box.installed == before)
        #expect(box.engine.store.activeName() == "dev")
        #expect(box.calls("nginx").last == "-t")  // no reload after a rejected test
        let log = box.engine.log.tail()
        #expect(log.contains { $0.contains("❌ nginx rejected the new config") })
        do {  // regression check: this was a known CLI/engine mismatch, now fixed
            #expect(log.allSatisfy { $0.wholeMatch(of: /\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] .*/) != nil }, "\(log)")
        }
    }

    @Test func failedReloadKeepsActive() async throws {
        let box = try ParitySandbox(machines: machinesJSON)
        try await box.engine.connect("dev")
        box.mark("fail-reload")

        await #expect(throws: NginxError.self) { try await box.engine.reload() }
        #expect(box.engine.store.activeName() == "dev")
        await #expect {
            try await box.engine.connect("prod")
        } throws: { error in
            guard case NginxError.reloadFailed(let output) = error else { return false }
            return output.contains("invalid PID")
        }
        #expect(box.engine.store.activeName() == "dev")
        await #expect(throws: NginxError.self) { try await box.engine.disconnect() }
        #expect(box.engine.store.activeName() == "dev")
    }

    @Test func rootNginxIsRefusedWithoutTouchingTheConfig() async throws {
        let box = try ParitySandbox(machines: machinesJSON)
        box.mark("root-nginx")
        await #expect(throws: NginxError.needsRoot(directory: box.conf.path)) { try await box.engine.connect("dev") }
        #expect(box.installed == nil)
        #expect(box.engine.store.activeName() == nil)
    }

    @Test func noActiveMachine() async throws {
        let box = try ParitySandbox(machines: machinesJSON)
        await #expect(throws: EngineError.noActiveMachine) { try await box.engine.reload() }
        try await box.engine.disconnect()  // nothing to do
        #expect(box.calls("nginx").isEmpty)
    }

    @Test func syncReloadsThenDisconnectsWhenTheMachineDisappears() async throws {
        let box = try ParitySandbox(machines: machinesJSON)
        try await box.engine.connect("dev")
        let upstream = box.root.appending(path: "upstream.json")
        let settings = SyncSettings(host: "fake-host", remotePath: upstream.path)

        try Data(#"{"dev": {"ip": "10.0.0.6", "services": {"ssh": {"local": 2222, "remote": 22}}}}"#.utf8).write(to: upstream)
        try await box.engine.sync(settings)
        #expect(box.engine.store.activeName() == "dev")
        #expect(box.installed?.contains("server 10.0.0.6:22;") == true)
        #expect(FileManager.default.fileExists(atPath: box.paths.home.appending(path: "machine.json.bak").path))

        try Data(#"{"prod": {"ip": "10.0.0.9", "services": {}}}"#.utf8).write(to: upstream)
        try await box.engine.sync(settings)
        #expect(box.engine.store.activeName() == nil)
        #expect(box.installed?.contains("upstream") == false)
        #expect(Array(try box.engine.store.load().keys) == ["prod"])
    }

    @Test func syncRejectsAnInvalidDownload() async throws {
        let box = try ParitySandbox(machines: machinesJSON)
        let upstream = box.root.appending(path: "upstream.json")
        try Data(#"{"dev": {"ip": "10.0.0.6", "services": {"bad name": {"local": 1, "remote": 2}}}}"#.utf8).write(to: upstream)
        await #expect(throws: SyncError.self) {
            try await box.engine.sync(SyncSettings(host: "fake-host", remotePath: upstream.path))
        }
        #expect(Set(try box.engine.store.load().keys) == ["dev", "prod"])
    }

    // MARK: CLI <-> engine on the same ~/.loki

    @Test(.disabled(if: !ParitySandbox.hasJQ, Comment(rawValue: ParitySandbox.noJQ)))
    func cliConnectIsSeenByTheEngine() async throws {
        let box = try ParitySandbox(machines: machinesJSON)
        let r = await box.cli("connect", "dev")
        #expect(r.succeeded, "\(r.output)")
        #expect(box.engine.store.activeName() == "dev")

        // The engine can carry on from there.
        try await box.engine.reload()
        #expect(ParitySandbox.normalized(box.installed) == (try expected(box, "dev")))
        try await box.engine.disconnect()
        #expect(await box.cli("status").output == "No active machine\n")
    }

    @Test(.disabled(if: !ParitySandbox.hasJQ, Comment(rawValue: ParitySandbox.noJQ)))
    func engineConnectIsSeenByTheCLI() async throws {
        let box = try ParitySandbox(machines: machinesJSON)
        try await box.engine.connect("dev")

        let status = await box.cli("status")
        #expect(status.succeeded)
        #expect(status.output == """
            📡 Active machine: dev (10.0.0.5)
             - web: local=8080, remote=80
             - db: local=5432, remote=5432

            """)
        #expect(await box.cli("list").output.contains("  * dev\n"))

        let r = await box.cli("disconnect")
        #expect(r.succeeded, "\(r.output)")
        #expect(box.engine.store.activeName() == nil)
    }
}
