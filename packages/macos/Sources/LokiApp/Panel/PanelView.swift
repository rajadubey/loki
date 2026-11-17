import AppKit
import LokiCore
import SwiftUI

enum PanelTab: String, CaseIterable { case services = "Services", machines = "Machines", log = "Log" }

/// Popover UI state (not @State: see Components.swift).
@MainActor @Observable
final class PanelUI {
    var tab: PanelTab = .services
    var switcherOpen = false
    var query = ""
    var showAll = false
}

/// The menu bar popover: machine switcher, health, services, machines and log.
struct PanelView: View {
    let model: AppModel
    let ui: PanelUI

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if model.setupNeedsAttention {
                    Button { model.openSettings?(.setup) } label: {
                        Label("Setup needs attention", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let update = model.update {
                    Button { NSWorkspace.shared.open(UpdateCheck.releasesPage) } label: {
                        Label("Loki \(update) is available: download it", systemImage: "arrow.down.circle.fill")
                            .font(.caption).foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Opens the release page with the new DMG")
                }
                if let error = model.loadError {
                    Label(error, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                if ui.switcherOpen {
                    MachineSwitcher(model: model, ui: ui)
                } else {
                    Picker("View", selection: Binding(ui, \.tab)) {
                        ForEach(PanelTab.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    switch ui.tab {
                    case .services: ServicesTab(model: model, ui: ui)
                    case .machines: MachinesTab(model: model, ui: ui)
                    case .log: LogTab(lines: model.logLines)
                    }
                }
            }
            .padding(14)
            Divider()
            PanelFooter(model: model).padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                ui.switcherOpen.toggle()
                ui.query = ""
            } label: {
                HStack(spacing: 4) {
                    Text(model.active ?? "Not connected").font(.headline).lineLimit(1)
                    Image(systemName: ui.switcherOpen ? "chevron.up" : "chevron.down").font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Switch machine")
            Spacer()
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.caption).foregroundStyle(.secondary)
            }
            if let ip = model.activeMachine?.ip {
                Button { copyToClipboard(ip) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Copy \(ip)").accessibilityLabel("Copy IP address")
            }
        }
    }
}

// MARK: - Machine rows and switcher

struct MachineRow: View {
    let model: AppModel
    let name: String
    let onPick: () -> Void

    var body: some View {
        let machine = model.machines[name]
        let reach = model.reachable[name]
        Button(action: onPick) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.caption.weight(.semibold))
                    .opacity(name == model.active ? 1 : 0)
                StatusDot(color: reach == nil ? .gray : reach! ? .green : .red)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).lineLimit(1)
                    Text("\(machine?.ip ?? "") · \(machine?.ports.count ?? 0) services")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 3).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name == model.active ? "Reconnect \(name)" : "Connect to \(name)")
        .accessibilityLabel("\(name)\(name == model.active ? ", connected" : "")")
    }
}

struct MachineSwitcher: View {
    let model: AppModel
    let ui: PanelUI

    var body: some View {
        let names = filterMachines(Array(model.machines.keys), query: ui.query, recents: model.recents)
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search machines", text: Binding(ui, \.query))
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let first = names.first { pick(first) } }
            if names.isEmpty {
                Text(model.machines.isEmpty ? "No machines yet." : "No machine matches “\(ui.query)”")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 2) { ForEach(names, id: \.self) { n in MachineRow(model: model, name: n) { pick(n) } } }
            }
            .frame(height: min(CGFloat(names.count) * 40, 320))
        }
    }

    private func pick(_ name: String) {
        ui.switcherOpen = false
        model.connect(name)
    }
}

// MARK: - Tabs

struct ServicesTab: View {
    let model: AppModel
    let ui: PanelUI

    var body: some View {
        if let machine = model.activeMachine {
            let c = model.counts
            HStack(spacing: 18) {
                Ring(up: c.up, slow: c.slow, down: c.down, total: machine.ports.count)
                VStack(spacing: 4) {
                    legend("Up", c.up, .green)
                    legend("Slow", c.slow, .orange)
                    legend("Down", c.down, .red)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Label("Services", systemImage: "server.rack").font(.subheadline.weight(.medium))
                Spacer()
                Text(machine.ip).font(.caption).foregroundStyle(.secondary)
            }

            let rows = sortedServices(machine)
            if ui.showAll {
                ScrollView { serviceList(rows) }.frame(height: 280)
            } else {
                serviceList(Array(rows.prefix(3)))
            }
            if rows.count > 3 {
                Button { ui.showAll.toggle() } label: {
                    HStack(spacing: 3) {
                        Text(ui.showAll ? "Show less" : "\(rows.count - 3) more")
                        Image(systemName: ui.showAll ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()
            HStack {
                Text("Uptime, last \(model.trendSpan)").font(.caption)
                Spacer()
                if model.trend.isEmpty {
                    Text("Collecting…").font(.caption).foregroundStyle(.secondary)
                } else {
                    TrendBars(values: model.trend)
                }
            }
            Divider()
            VStack(spacing: 3) {
                keyValue("Connected since", model.connectedSince.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–")
                keyValue("Last sync", model.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "–")
                HStack {
                    Text("nginx").foregroundStyle(.secondary)
                    Spacer()
                    StatusDot(color: model.nginxRunning ? .green : .red)
                    Text(model.nginxRunning ? "running" : "stopped")
                }
                .font(.caption)
            }
            HStack(spacing: 8) {
                LinkButton(title: "Open log") {
                    NSWorkspace.shared.open([model.engine.paths.log],
                                            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                            configuration: NSWorkspace.OpenConfiguration())
                }
                LinkButton(title: "Edit machines") { model.openSettings?(.machines) }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2).foregroundStyle(.secondary)
                Text("Pick a machine to route your local ports to it.").font(.callout).multilineTextAlignment(.center)
                Button(model.machines.isEmpty ? "Add machines" : "Choose machine") {
                    if model.machines.isEmpty { model.openSettings?(.machines) } else { ui.switcherOpen = true }
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }

    /// Problems first so the three visible rows are the ones that matter.
    private func sortedServices(_ m: Machine) -> [(name: String, ports: ResolvedPorts)] {
        let rank: (Health) -> Int = { [.down: 0, .slow: 1, .unknown: 2, .up: 3][$0] ?? 4 }
        return m.ports.map { (name: $0.key, ports: $0.value) }.sorted {
            let a = rank(model.status[$0.name]?.health ?? .unknown), b = rank(model.status[$1.name]?.health ?? .unknown)
            return a != b ? a < b : $0.name < $1.name
        }
    }

    private func serviceList(_ rows: [(name: String, ports: ResolvedPorts)]) -> some View {
        VStack(spacing: 10) {
            ForEach(rows, id: \.name) { ServiceRow(model: model, name: $0.name, ports: $0.ports) }
        }
    }

    private func legend(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack { StatusDot(color: color, size: 8); Text(label); Spacer(); Text("\(n)").monospacedDigit() }.font(.callout)
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack { Text(key).foregroundStyle(.secondary); Spacer(); Text(value) }.font(.caption)
    }
}

struct ServiceRow: View {
    let model: AppModel
    let name: String
    let ports: ResolvedPorts

    var body: some View {
        let st = model.status[name] ?? ServiceStatus()
        let latency: String = switch st.health {
        case .down: "unreachable"
        case .unknown: "–"
        default: "\(st.latencyMs ?? 0) ms"
        }
        let fraction: Double = switch st.health {
        case .down: 1
        case .unknown: 0
        default: min(1, max(0.04, Double(st.latencyMs ?? 0) / 600))
        }
        let caption = st.health == .down ? model.downLabel(for: name)
            : (st.http ?? (st.health == .unknown ? "Checking…" : "TCP open"))
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).lineLimit(1)
                Spacer()
                Text(latency).font(.caption).foregroundStyle(st.health == .down ? Color.red : .secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(st.health.color).frame(width: g.size.width * fraction)
                }
            }
            .frame(height: 4)
            HStack {
                Text(":\(String(ports.local)) → \(String(ports.remote))")
                Spacer()
                Text(caption)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { openURL("http://localhost:\(ports.local)") }
        .contextMenu {
            Button("Open in browser") { openURL("http://localhost:\(ports.local)") }
            Button("Copy localhost:\(String(ports.local))") { copyToClipboard("localhost:\(ports.local)") }
        }
        .help("Open http://localhost:\(ports.local)")
        .accessibilityElement(children: .combine)
    }
}

struct MachinesTab: View {
    let model: AppModel
    let ui: PanelUI

    var body: some View {
        let names = model.machines.keys.sorted()
        ScrollView {
            VStack(spacing: 2) { ForEach(names, id: \.self) { n in MachineRow(model: model, name: n) { model.connect(n) } } }
        }
        .frame(height: min(max(CGFloat(names.count), 1) * 40, 360))
        HStack {
            Button("Edit machines…") { model.openSettings?(.machines) }
            Spacer()
            if model.active != nil { Button("Disconnect") { model.disconnect() } }
        }
    }
}

struct LogTab: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let bad = ["error", "failed", "emerg", "❌"].contains { line.lowercased().contains($0) }
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(bad ? Color.red : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(height: 320)
        .defaultScrollAnchor(.bottom)
    }
}

struct PanelFooter: View {
    let model: AppModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Loki \(model.version)")
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Next check in \(max(0, Int(model.nextCheck.timeIntervalSince(ctx.date))))s")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu("Options") {
                Button("Check now") { Task { await model.check() } }
                Button("Sync machines") { model.sync() }
                Button("Reload nginx") { model.reloadNginx() }.disabled(model.active == nil)
                Button("Disconnect") { model.disconnect() }.disabled(model.active == nil)
                Divider()
                Button("Settings…") { model.openSettings?(.machines) }.keyboardShortcut(",")
                Button("Setup…") { model.openSettings?(.setup) }
                Text("Toggle panel: ⌥⌘L")
                Divider()
                Button("Quit Loki") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
