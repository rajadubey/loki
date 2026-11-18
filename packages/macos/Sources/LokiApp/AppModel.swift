import AppKit
import LokiCore
import Observation
import ServiceManagement

enum SettingsTab: String, CaseIterable {
    case machines = "Machines", sync = "Sync", setup = "Setup", general = "General"
}

/// App state: what's in ~/.loki, live health, setup status. All changes go through `LokiEngine`.
@MainActor @Observable
final class AppModel {
    let engine = LokiEngine()
    let assistant = SetupAssistant()

    /// machine.json as written, for the editor; `machines` is every machine with its services.
    var machineFile = MachineFile()
    var machines: MachineList = [:]
    var active: String?
    var loadError: String?
    var status: [String: ServiceStatus] = [:]  // services of the active machine
    var reachable: [String: Bool] = [:]        // machine -> any service accepts TCP
    var downSince: [String: Date] = [:]        // "machine/service" -> first failed check
    var trend: [Double] = []                    // share of services up per check, last hour
    var logLines: [String] = []
    var nginxRunning = false
    var nextCheck = Date()
    var busy: String?
    var connectedSince: Date?
    var lastSync: Date?
    var setupChecks: [SetupCheck] = []
    var openAtLogin = SMAppService.mainApp.status == .enabled
    var recents: [String] = UserDefaults.standard.stringArray(forKey: "recents") ?? []
    /// Seconds between health checks. App-only, so it lives in the app's defaults, not ~/.loki.
    var interval = TimeInterval(HealthInterval.sanitized(UserDefaults.standard.integer(forKey: "healthInterval")))
    /// Version of a newer release, when GitHub has one.
    var update: String?

    /// Whether the menu bar panel shows. Closed, a check probes only the connected machine's services,
    /// which the menu bar title and notifications need; open, also what only the panel shows: the
    /// other machines' reachability, HTTP status and whether nginx runs.
    @ObservationIgnored var panelOpen = false
    @ObservationIgnored private var lastFullCheck = Date.distantPast
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var openSettings: ((SettingsTab) -> Void)?
    @ObservationIgnored private var notified: Set<String> = []
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var recheck = false
    @ObservationIgnored private var loop: Task<Void, Never>?

    var store: MachineStore { engine.store }
    var activeMachine: Machine? { active.flatMap { machines[$0] } }
    var setupNeedsAttention: Bool { setupChecks.contains { $0.state == .failed } }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    var counts: (up: Int, slow: Int, down: Int) {
        var c = (up: 0, slow: 0, down: 0)
        for s in status.values {
            switch s.health {
            case .up: c.up += 1
            case .slow: c.slow += 1
            case .down: c.down += 1
            case .unknown: break
            }
        }
        return c
    }

    // MARK: State

    func reload() {
        do {
            machineFile = try store.loadFile()
            machines = machineFile.all
            loadError = machines.isEmpty ? "No machines yet. Add or sync them in Settings." : nil
        } catch {
            loadError = error.localizedDescription
        }
        let name = store.activeName()
        if name != active { status = [:] }
        active = name
        connectedSince = name == nil ? nil : store.modified(engine.paths.active)
        lastSync = store.modified(engine.paths.machines)
        onChange?()
    }

    func readLog() {
        logLines = engine.log.tail(50)
    }

    /// The panel opened: fresh files and log, and a full check unless one just ran.
    func panelOpened() {
        panelOpen = true
        reload()
        readLog()
        if Date().timeIntervalSince(lastFullCheck) > 15 { Task { await check() } }
    }

    func refreshSetup() async {
        setupChecks = await assistant.inspect()
    }

    /// Older versions (app and CLI) created ~/.loki readable by every user of the Mac.
    func makeDataFolderPrivate() {
        do {
            try engine.paths.makePrivate()
        } catch {
            engine.log.append("Couldn't make \(engine.paths.home.path) private (chmod 700 it): \(error.localizedDescription)")
        }
    }

    // MARK: Health

    /// (Re)starts the check loop; the first check runs right away.
    func startLoop() {
        loop?.cancel()
        loop = Task {
            while !Task.isCancelled {
                await check()
                nextCheck = Date().addingTimeInterval(interval)
                try? await Task.sleep(for: .seconds(interval))  // throws when cancelled, which ends the loop
            }
        }
    }

    /// Saves the choice and restarts the loop, so it applies now instead of after the current wait.
    func setInterval(_ seconds: Int) {
        let seconds = HealthInterval.sanitized(seconds)
        guard TimeInterval(seconds) != interval else { return }
        interval = TimeInterval(seconds)
        UserDefaults.standard.set(seconds, forKey: "healthInterval")
        trend = []  // bars from the old interval would misstate the time they cover
        startLoop()
    }

    /// What the trend's 60 bars cover: 60 checks × `interval` seconds = `interval` minutes.
    var trendSpan: String {
        let minutes = Int(interval)
        return minutes == 60 ? "hour" : minutes % 60 == 0 ? "\(minutes / 60) hours" : "\(minutes) min"
    }

    /// One task for the app's lifetime: asks GitHub at launch, then daily, or hourly while it can't be
    /// reached (at login Wi-Fi often isn't up yet).
    func startUpdateChecks() {
        Task {
            while !Task.isCancelled {
                let outcome = await UpdateCheck.run(current: version)
                if case .newer(let latest) = outcome { update = latest }
                try? await Task.sleep(for: .seconds(outcome == .unreachable ? 3_600 : 86_400))
            }
        }
    }

    /// A check asked for while one runs (after Connect, say) isn't dropped: the running one goes
    /// again with fresh state, or the old machine's status would stay up until the next interval.
    func check() async {
        guard !checking else { recheck = true; return }
        checking = true
        defer { checking = false }
        repeat {
            recheck = false
            await checkOnce()
        } while recheck
    }

    private func checkOnce() async {
        reload()
        let full = panelOpen
        if full {
            lastFullCheck = Date()
            nginxRunning = await engine.nginx.isRunning()
        }

        // ponytail: one TCP probe per service per check; batch if machine.json grows to thousands.
        var latency: [String: [String: Int?]] = [:]
        let probed = full ? machines : machines.filter { $0.key == active }
        await withTaskGroup(of: (String, String, Int?).self) { group in
            for (m, machine) in probed {
                for (s, p) in machine.ports {
                    group.addTask { (m, s, await tcpProbe(host: machine.ip, port: p.remote)) }
                }
            }
            for await (m, s, ms) in group { latency[m, default: [:]][s] = ms }
        }
        let seen = latency.mapValues { $0.values.contains { $0 != nil } }
        reachable = full ? seen : reachable.merging(seen) { $1 }

        guard let name = active, let machine = machines[name] else {
            status = [:]
            onChange?()
            return
        }
        var http: [String: String] = [:]
        if full {
            await withTaskGroup(of: (String, String?).self) { group in
                for (s, p) in machine.ports { group.addTask { (s, await httpProbe(port: p.local)) } }
                for await (s, h) in group { http[s] = h }
            }
        }

        let now = Date()
        var next: [String: ServiceStatus] = [:]
        for (s, p) in machine.ports {
            let ms = latency[name]?[s] ?? nil
            // Closed, the last HTTP status stays: only the panel shows it, and opening it checks again
            next[s] = ServiceStatus(health: classify(ms), latencyMs: ms, http: full ? http[s] : status[s]?.http)
            let key = "\(name)/\(s)"
            if ms == nil {
                let since = downSince[key] ?? now
                downSince[key] = since
                if now.timeIntervalSince(since) >= 60, !notified.contains(key) {
                    notified.insert(key)
                    notify(title: "\(s) is down", body: "\(name) · \(machine.ip):\(p.remote)")
                }
            } else {
                downSince[key] = nil
                notified.remove(key)
            }
        }
        status = next
        let c = counts
        trend.append(Double(c.up + c.slow) / Double(max(1, next.count)))
        if trend.count > 60 { trend.removeFirst(trend.count - 60) }
        onChange?()
    }

    func downLabel(for service: String) -> String {
        guard let name = active, let since = downSince["\(name)/\(service)"] else { return "Down" }
        return downText(since: since)
    }

    // MARK: Actions

    func connect(_ name: String) {
        recents = Array(([name] + recents.filter { $0 != name }).prefix(3))
        UserDefaults.standard.set(recents, forKey: "recents")
        perform("Connecting") { try await $0.connect(name) }
    }

    func disconnect() { perform("Disconnecting") { try await $0.disconnect() } }

    func reloadNginx() { perform("Reloading") { try await $0.reload() } }

    func sync() {
        let settings = SyncSettings.load(from: engine.paths)
        guard settings.isConfigured else { openSettings?(.sync); return }
        perform("Syncing") { try await $0.sync(settings) }
    }

    /// Runs an engine operation with a busy label; shows failures in an alert; refreshes state.
    func perform(_ label: String, _ operation: @escaping @Sendable (LokiEngine) async throws -> Void) {
        let engine = self.engine
        Task {
            busy = label
            defer { busy = nil }
            do {
                try await operation(engine)
            } catch {
                showError(title: "\(label.replacingOccurrences(of: "ing", with: "")) failed", error)
            }
            status = [:]
            await check()
            readLog()
        }
    }

    func showError(title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        if case NginxError.needsRoot = error { alert.addButton(withTitle: "Open Setup"); alert.addButton(withTitle: "OK") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, case NginxError.needsRoot = error { openSettings?(.setup) }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            showError(title: "Couldn't change Open at login", error)
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func notify(title: String, body: String) {
        // ponytail: osascript works for an unsigned app but shows under Script Editor;
        // switch to UNUserNotificationCenter once the app is Developer ID signed.
        let script = "display notification \(appleString(body)) with title \(appleString(title))"
        Task.detached { _ = await ProcessRunner().run("/usr/bin/osascript", ["-e", script]) }
    }

    private func appleString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
