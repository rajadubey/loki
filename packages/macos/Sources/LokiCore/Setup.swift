import Foundation

public enum SetupItem: String, CaseIterable, Sendable {
    case nginxInstalled, nginxRunning, configWritable, streamInclude, machines, sync
}

public enum CheckState: Equatable, Sendable {
    case ok, warning, failed
}

/// One-click remedies. `openMachines` / `openSync` are navigation, handled by the UI.
public enum SetupFix: Equatable, Sendable {
    case installNginx
    case startNginx
    case removeStalePidFileAndStart(path: String)
    case stopRootNginx(pidPath: String?)
    case takeOwnership(directory: String)
    case addStreamInclude(nginxConf: String)
    case openMachines
    case openSync

    public var label: String {
        switch self {
        case .installNginx: "Install nginx"
        case .startNginx: "Start nginx"
        case .removeStalePidFileAndStart: "Fix and start"
        case .stopRootNginx: "Switch to my user"
        case .takeOwnership: "Make it mine"
        case .addStreamInclude: "Add include"
        case .openMachines: "Edit machines"
        case .openSync: "Set up sync"
        }
    }

    /// Fixes that show the macOS administrator prompt.
    public var needsAdmin: Bool {
        switch self {
        case .removeStalePidFileAndStart, .stopRootNginx, .takeOwnership: true
        default: false
        }
    }
}

public struct SetupCheck: Identifiable, Equatable, Sendable {
    public let id: SetupItem
    public let state: CheckState
    public let title: String
    public let detail: String
    public let fix: SetupFix?

    public init(_ id: SetupItem, _ state: CheckState, _ title: String, _ detail: String, fix: SetupFix? = nil) {
        self.id = id
        self.state = state
        self.title = title
        self.detail = detail
        self.fix = fix
    }
}

public struct SetupError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Checks everything loki needs on this Mac and applies the fixes the user clicks.
public struct SetupAssistant: Sendable {
    public let runner: CommandRunner
    public let paths: LokiPaths
    public let nginx: Nginx

    public init(paths: LokiPaths = LokiPaths(), runner: CommandRunner = ProcessRunner()) {
        self.runner = runner
        self.paths = paths
        self.nginx = Nginx(runner: runner)
    }

    public func inspect() async -> [SetupCheck] {
        var checks: [SetupCheck] = []
        let installed = await nginx.isInstalled()
        if installed {
            checks.append(SetupCheck(.nginxInstalled, .ok, "nginx is installed", "loki routes your local ports through nginx."))
            checks.append(await runningCheck())
            let conf = await nginx.configFile()
            checks.append(writableCheck(conf))
            checks.append(streamCheck(conf))
        } else {
            checks.append(SetupCheck(.nginxInstalled, .failed, "nginx isn't installed",
                                     "loki needs nginx from Homebrew (brew install nginx).", fix: .installNginx))
        }
        checks.append(machinesCheck())
        checks.append(syncCheck())
        return checks
    }

    func runningCheck() async -> SetupCheck {
        let running = await nginx.isRunning()
        let root = await nginx.runsAsRoot()
        let pidPath = await nginx.pidFilePath()
        if running && root {
            return SetupCheck(.nginxRunning, .failed, "nginx runs as root",
                              "The app can't reload a root nginx. Switch it to run as you; local ports above 1024 don't need root.",
                              fix: .stopRootNginx(pidPath: pidPath))
        }
        if running {
            return SetupCheck(.nginxRunning, .ok, "nginx is running as you", "loki can reload it without sudo.")
        }
        if let pidPath, Self.ownedByRoot(pidPath) {
            return SetupCheck(.nginxRunning, .failed, "nginx can't start",
                              "A root-owned \(pidPath) left by an earlier `sudo nginx` blocks it. Removing it needs your password once.",
                              fix: .removeStalePidFileAndStart(path: pidPath))
        }
        return SetupCheck(.nginxRunning, .failed, "nginx isn't running", "Start it as a Homebrew service so it also starts at login.",
                          fix: .startNginx)
    }

    func writableCheck(_ conf: URL?) -> SetupCheck {
        guard let dir = conf?.deletingLastPathComponent() else {
            return SetupCheck(.configWritable, .failed, "nginx config not found", "`nginx -t` didn't report a config file.")
        }
        if FileManager.default.isWritableFile(atPath: dir.path) {
            return SetupCheck(.configWritable, .ok, "Config folder is writable", dir.path)
        }
        return SetupCheck(.configWritable, .failed, "Can't write to \(dir.path)",
                          "loki writes remote.conf there. Make the folder yours (needs your password once).",
                          fix: .takeOwnership(directory: dir.path))
    }

    func streamCheck(_ conf: URL?) -> SetupCheck {
        guard let conf, let text = try? String(contentsOf: conf, encoding: .utf8) else {
            return SetupCheck(.streamInclude, .failed, "Can't read nginx.conf", "loki needs it to include remote.conf.")
        }
        if StreamInclude.isConfigured(in: text) {
            return SetupCheck(.streamInclude, .ok, "nginx.conf includes remote.conf", "Inside a stream { } block, as TCP proxies need.")
        }
        return SetupCheck(.streamInclude, .failed, "nginx.conf doesn't include remote.conf",
                          "loki's proxies only work once nginx.conf has `stream { include …/remote.conf; }`. A backup is kept.",
                          fix: .addStreamInclude(nginxConf: conf.path))
    }

    func machinesCheck() -> SetupCheck {
        do {
            let machines = try MachineStore(paths: paths).load()
            if machines.isEmpty {
                return SetupCheck(.machines, .warning, "No machines yet", "Sync them from your team's host or add them yourself.", fix: .openMachines)
            }
            let issues = validate(machines)
            if !issues.isEmpty {
                return SetupCheck(.machines, .warning, "machine.json has \(issues.count) problem\(issues.count == 1 ? "" : "s")",
                                  issues.first!.description, fix: .openMachines)
            }
            return SetupCheck(.machines, .ok, "\(machines.count) machine\(machines.count == 1 ? "" : "s")", paths.machines.path)
        } catch {
            return SetupCheck(.machines, .failed, "machine.json can't be read", error.localizedDescription, fix: .openMachines)
        }
    }

    func syncCheck() -> SetupCheck {
        let settings = SyncSettings.load(from: paths)
        if settings.isConfigured {
            return SetupCheck(.sync, .ok, "Sync from \(settings.user)@\(settings.host)", settings.remotePath)
        }
        return SetupCheck(.sync, .warning, "Sync isn't set up", "Optional: fetch machine.json from a shared host over SSH.", fix: .openSync)
    }

    // MARK: Fixes

    public func apply(_ fix: SetupFix) async throws {
        let admin = AdminCommand(runner: runner)
        switch fix {
        case .installNginx:
            try check(await runner.run("brew", ["install", "nginx"]), "brew install nginx failed")
        case .startNginx:
            try await startService()
        case .removeStalePidFileAndStart(let path):
            try check(await admin.run("rm -f \(shellQuote(path))"), "Couldn't remove \(path)")
            try await startService()
        case .stopRootNginx(let pidPath):
            // Stop the root copy, then start ours. `sudo brew services` leaves a plist in /Library/LaunchDaemons
            // (sh.brew.nginx since Homebrew 7) that starts root nginx again at every boot, so delete it, not just unload it.
            var cmd = "PATH=\(shellQuote(ProcessRunner.defaultPath)); launchctl bootout system/homebrew.mxcl.nginx 2>/dev/null; launchctl bootout system/sh.brew.nginx 2>/dev/null; rm -f /Library/LaunchDaemons/homebrew.mxcl.nginx.plist /Library/LaunchDaemons/sh.brew.nginx.plist; nginx -s stop 2>/dev/null; sleep 1"
            if let pidPath { cmd += "; rm -f \(shellQuote(pidPath))" }
            try check(await admin.run(cmd), "Couldn't stop the root nginx")
            try await startService()
        case .takeOwnership(let dir):
            try check(await admin.run("chown -R \(shellQuote(NSUserName())) \(shellQuote(dir))"), "Couldn't change the owner of \(dir)")
        case .addStreamInclude(let confPath):
            try await addStreamInclude(confPath: confPath)
        case .openMachines, .openSync:
            break  // navigation, handled by the UI
        }
    }

    func startService() async throws {
        let result = await runner.run("brew", ["services", "restart", "nginx"])
        try check(result, "brew services couldn't start nginx")
    }

    /// Adds the include with a backup; restores nginx.conf if `nginx -t` then fails.
    func addStreamInclude(confPath: String) async throws {
        let conf = URL(fileURLWithPath: confPath)
        let original = try String(contentsOf: conf, encoding: .utf8)
        let remoteConf = conf.deletingLastPathComponent().appending(path: "remote.conf")
        if !FileManager.default.fileExists(atPath: remoteConf.path) {
            // nginx -t fails on an include of a missing file
            try Data("# Managed by loki\n".utf8).write(to: remoteConf)
        }
        try Data(original.utf8).write(to: URL(fileURLWithPath: confPath + ".loki-backup"), options: .atomic)
        try Data(StreamInclude.adding(to: original, includePath: remoteConf.path).utf8).write(to: conf, options: .atomic)
        let test = await nginx.test()
        guard test.succeeded else {
            try? Data(original.utf8).write(to: conf, options: .atomic)
            throw SetupError(message: "nginx rejected the change, so nginx.conf was restored.\n\(test.output)")
        }
        if await nginx.isRunning() { _ = await nginx.reload() }
    }

    private func check(_ result: CommandResult, _ message: String) throws {
        guard result.succeeded else {
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            // osascript reports a cancelled password prompt as error -128
            if output.contains("-128") { throw SetupError(message: "Cancelled.") }
            throw SetupError(message: output.isEmpty ? message : "\(message):\n\(output)")
        }
    }

    static func ownedByRoot(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0
    }
}
