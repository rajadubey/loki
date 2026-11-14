import AppKit
import LokiCore
import SwiftUI

/// Settings window state (not @State: see Components.swift).
@MainActor @Observable
final class SettingsUI {
    var tab: SettingsTab = .machines
    let machines = MachinesEditorModel()
    let sync = SyncForm()
    var fixing: SetupItem?
    var setupError: String?
}

struct SettingsView: View {
    let model: AppModel
    let ui: SettingsUI

    var body: some View {
        TabView(selection: Binding(ui, \.tab)) {
            MachinesEditorView(model: model, editor: ui.machines)
                .tabItem { Label("Machines", systemImage: "server.rack") }.tag(SettingsTab.machines)
            SyncSettingsView(model: model, form: ui.sync)
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.sync)
            SetupView(model: model, ui: ui)
                .tabItem { Label("Setup", systemImage: "checklist") }.tag(SettingsTab.setup)
            GeneralView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
        }
        .frame(minWidth: 620, minHeight: 460)
    }
}

// MARK: - Sync

@MainActor @Observable
final class SyncForm {
    var user = ""
    var host = ""
    var port = ""
    var remotePath = ""
    var status: (text: String, ok: Bool)?
    var busy = false

    var settings: SyncSettings {
        SyncSettings(user: user.trimmingCharacters(in: .whitespaces), host: host.trimmingCharacters(in: .whitespaces),
                     port: Int(port.trimmingCharacters(in: .whitespaces)) ?? 0,
                     remotePath: remotePath.trimmingCharacters(in: .whitespaces))
    }

    func load(_ s: SyncSettings) {
        user = s.user
        host = s.host
        port = String(s.port)
        remotePath = s.remotePath
    }

    /// LOKI_SSH_* exports from the first shell profile that has them (apps never read these files).
    static func fromShellProfiles() -> (SyncSettings, String)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile"] {
            let url = home.appending(path: name)
            if let text = try? String(contentsOf: url, encoding: .utf8), SyncSettings.isPresent(in: text) {
                return (SyncSettings.parse(text), "~/" + name)
            }
        }
        return nil
    }
}

struct SyncSettingsView: View {
    let model: AppModel
    let form: SyncForm

    var body: some View {
        Form {
            Section {
                TextField("Host", text: Binding(form, \.host), prompt: Text("54.123.45.67"))
                TextField("User", text: Binding(form, \.user), prompt: Text("ubuntu"))
                TextField("Port", text: Binding(form, \.port), prompt: Text("22"))
                TextField("machines.json path", text: Binding(form, \.remotePath), prompt: Text("/opt/machines.json"))
            } header: {
                Text("Fetch machine.json over SSH")
            } footer: {
                Text("Uses your SSH keys without prompting, so the host must accept key login and already be in ~/.ssh/known_hosts. Saved to ~/.loki/config, which the loki CLI reads too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status = form.status {
                Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(status.ok ? .green : .red)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Import from shell profile") { importFromProfile() }
                Spacer()
                if form.busy { ProgressView().controlSize(.small) }
                Button("Test connection") { test() }.disabled(form.busy)
                Button("Save") { save() }.disabled(form.busy)
                Button("Save and sync") { save(thenSync: true) }.buttonStyle(.borderedProminent).disabled(form.busy)
            }
        }
        .formStyle(.grouped)
        .onAppear { form.load(SyncSettings.load(from: model.engine.paths)) }
    }

    private func importFromProfile() {
        if let (settings, file) = SyncForm.fromShellProfiles() {
            form.load(settings)
            form.status = ("Loaded from \(file). Save to keep it.", true)
        } else {
            form.status = ("No LOKI_SSH_* settings found in your shell profiles.", false)
        }
    }

    @discardableResult
    private func save(thenSync: Bool = false) -> Bool {
        let s = form.settings
        if !s.problems.isEmpty {
            form.status = (s.problems.joined(separator: " "), false)
            return false
        }
        do {
            try s.save(to: model.engine.paths)
            form.status = ("Saved", true)
            Task { await model.refreshSetup() }
            if thenSync { model.sync() }
            return true
        } catch {
            form.status = (error.localizedDescription, false)
            return false
        }
    }

    private func test() {
        let s = form.settings
        form.busy = true
        form.status = nil
        Task {
            let result = await model.engine.syncer.testConnection(s)
            form.busy = false
            form.status = result.succeeded
                ? ("Connected, and \(s.remotePath) is readable.", true)
                : (result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Connection failed (exit \(result.status))." : result.output.trimmingCharacters(in: .whitespacesAndNewlines), false)
        }
    }
}

// MARK: - Setup

struct SetupView: View {
    let model: AppModel
    let ui: SettingsUI

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(model.setupChecks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: check.state.symbol.name).foregroundStyle(check.state.symbol.color)
                            .font(.title3).accessibilityLabel(String(describing: check.state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title).font(.body.weight(.medium))
                            Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        if let fix = check.fix {
                            if ui.fixing == check.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(fix.needsAdmin ? "\(fix.label)…" : fix.label) { apply(fix, for: check.id) }
                                    .disabled(ui.fixing != nil)
                                    .help(fix.needsAdmin ? "Asks for your password" : "")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let error = ui.setupError {
                Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
                    .textSelection(.enabled).padding(.horizontal, 12).padding(.top, 8)
            }
            HStack {
                Text(model.setupNeedsAttention ? "Fix the red items so loki can switch machines." : "Everything loki needs is in place.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check again") { Task { await model.refreshSetup() } }
            }
            .padding(12)
        }
        .task { await model.refreshSetup() }
    }

    private func apply(_ fix: SetupFix, for item: SetupItem) {
        switch fix {
        case .openMachines: ui.tab = .machines; return
        case .openSync: ui.tab = .sync; return
        default: break
        }
        ui.fixing = item
        ui.setupError = nil
        Task {
            do {
                try await model.assistant.apply(fix)
            } catch {
                ui.setupError = error.localizedDescription
            }
            ui.fixing = nil
            await model.refreshSetup()
            await model.check()
        }
    }
}

// MARK: - General

struct GeneralView: View {
    let model: AppModel

    var body: some View {
        Form {
            Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            LabeledContent("Toggle the panel", value: "⌥⌘L")
            LabeledContent("Health check", value: "Every \(Int(model.interval)) seconds")
            LabeledContent("Data folder") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.engine.paths.machines]) }
            }
            LabeledContent("Version", value: model.version)
        }
        .formStyle(.grouped)
    }
}
