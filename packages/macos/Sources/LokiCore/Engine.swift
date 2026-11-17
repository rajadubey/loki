import Foundation

public enum EngineError: Error, LocalizedError, Equatable {
    case unknownMachine(String)
    case noActiveMachine

    public var errorDescription: String? {
        switch self {
        case .unknownMachine(let name): "There's no machine called “\(name)” in machine.json."
        case .noActiveMachine: "No machine is connected."
        }
    }
}

/// loki's operations, the Swift counterpart of loki.sh's connect / reload / disconnect / sync.
/// Same files, same log, same rule: ~/.loki/active changes only after nginx accepted the config.
public struct LokiEngine: Sendable {
    public let store: MachineStore
    public let nginx: Nginx
    public let syncer: Syncer
    public let log: LokiLog

    public init(paths: LokiPaths = LokiPaths(), runner: CommandRunner = ProcessRunner()) {
        store = MachineStore(paths: paths)
        nginx = Nginx(runner: runner)
        syncer = Syncer(runner: runner)
        log = LokiLog(url: paths.log)
    }

    public var paths: LokiPaths { store.paths }

    public func connect(_ name: String) async throws {
        let machines = try store.load()
        guard let machine = machines[name] else { throw EngineError.unknownMachine(name) }
        try Self.checkRenderable(name, machine)
        log.append("Attempting to connect to machine: \(name)")
        try await apply(NginxConfig.render(machineName: name, machine: machine))
        try store.setActive(name)
        log.append("✅ Connected to: \(name)")
    }

    /// Regenerates the active machine's config (after editing or syncing machines).
    public func reload() async throws {
        guard let name = store.activeName() else { throw EngineError.noActiveMachine }
        guard let machine = try store.load()[name] else { throw EngineError.unknownMachine(name) }
        try Self.checkRenderable(name, machine)
        try await apply(NginxConfig.render(machineName: name, machine: machine))
        log.append("✅ Reloaded NGINX with new config for \(name)")
    }

    /// A hand-edited machine.json can hold an IP or name that would inject text into nginx.conf
    /// (e.g. `"ip": "1.2.3.4; include /x"`). Null ports are fine: those services are skipped.
    static func checkRenderable(_ name: String, _ machine: Machine) throws {
        let unsafe = validate([name: machine]).filter {
            if case .missingPort = $0 { return false }
            return true
        }
        if !unsafe.isEmpty { throw StoreError.invalid(unsafe) }
    }

    /// Empties the proxy (header-only remote.conf) and clears the active machine.
    public func disconnect() async throws {
        guard let name = store.activeName() else { return }
        let machine = try store.load()[name] ?? Machine(ip: "", services: [:])
        try await apply(NginxConfig.render(machineName: name, machine: machine, includeServices: false))
        try store.setActive(nil)
        log.append("✅ Disconnected from \(name)")
    }

    /// Fetches machine.json, then reloads the active machine; if it no longer exists, disconnects.
    public func sync(_ settings: SyncSettings) async throws {
        // Before logging: a refused URL may hold a user name and password
        guard settings.problems.isEmpty else { throw SyncError.notConfigured(settings.problems) }
        log.append("Fetching machines.json from \(settings.source) ...")
        let machines = try await syncer.sync(settings, into: store)
        log.append("✅ Updated local machines.json (\(machines.count) machines)")
        guard let active = store.activeName() else { return }
        if machines[active] != nil {
            try await reload()
        } else {
            log.append("Active machine \(active) is no longer in machine.json, disconnecting")
            try await apply("# Auto-generated remote.conf: \(NginxConfig.oneLine(active)) was removed from machine.json\n")
            try store.setActive(nil)
        }
    }

    private func apply(_ config: String) async throws {
        // The ~/.loki copy is only for inspection; installing it next to nginx.conf is what counts.
        try? paths.ensurePrivateHome()
        try? writePrivately(Data(config.utf8), to: paths.generatedConf)
        do {
            try await nginx.install(config: config)
        } catch {
            log.append("❌ \(error.localizedDescription)")
            throw error
        }
    }
}
