import AppKit
import LokiCore
import SwiftUI
import UniformTypeIdentifiers

struct ServiceDraft: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var local: String
    var remote: String
}

struct MachineDraft: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var ip: String
    var services: [ServiceDraft]
    /// Name in machine.json when loaded; nil for a new machine. Used to follow renames of the active machine.
    var originalName: String?
}

/// Editable copy of machine.json. Nothing is written until Save.
@MainActor @Observable
final class MachinesEditorModel {
    var drafts: [MachineDraft] = []
    var selection: UUID?
    var problems: [String] = []
    var message: String?
    private var saved: [MachineDraft] = []

    var hasChanges: Bool { drafts != saved }
    var selectedIndex: Int? { drafts.firstIndex { $0.id == selection } }

    func load(_ machines: MachineList) {
        drafts = machines.keys.sorted().map { name in
            let m = machines[name]!
            return MachineDraft(name: name, ip: m.ip,
                                services: m.services.keys.sorted().map { s in
                                    ServiceDraft(name: s, local: m.services[s]!.local.map(String.init) ?? "",
                                                 remote: m.services[s]!.remote.map(String.init) ?? "")
                                },
                                originalName: name)
        }
        saved = drafts
        if selectedIndex == nil { selection = drafts.first?.id }
        problems = []
    }

    /// The drafts as a machine list, or the reasons they can't be one.
    func machineList() -> Result<MachineList, Problems> {
        var list: MachineList = [:]
        var problems: [String] = []
        for d in drafts {
            let name = d.name.trimmingCharacters(in: .whitespaces)
            if list[name] != nil { problems.append("Two machines are called “\(name)”.") }
            var services: [String: Ports] = [:]
            for s in d.services {
                let sname = s.name.trimmingCharacters(in: .whitespaces)
                if services[sname] != nil { problems.append("\(name): two services are called “\(sname)”.") }
                let local = Int(s.local.trimmingCharacters(in: .whitespaces))
                let remote = Int(s.remote.trimmingCharacters(in: .whitespaces))
                if local == nil && !s.local.isEmpty { problems.append("\(name) → \(sname): local port “\(s.local)” isn't a number.") }
                if remote == nil && !s.remote.isEmpty { problems.append("\(name) → \(sname): remote port “\(s.remote)” isn't a number.") }
                services[sname] = Ports(local: local, remote: remote)
            }
            list[name] = Machine(ip: d.ip.trimmingCharacters(in: .whitespaces), services: services)
        }
        problems += validate(list).map(\.description)
        return problems.isEmpty ? .success(list) : .failure(Problems(list: problems))
    }

    struct Problems: Error { let list: [String] }

    func addMachine() {
        var n = 1
        while drafts.contains(where: { $0.name == "machine_\(n)" }) { n += 1 }
        let d = MachineDraft(name: "machine_\(n)", ip: "", services: [ServiceDraft(name: "web", local: "", remote: "")])
        drafts.append(d)
        selection = d.id
    }

    func removeSelected() {
        guard let i = selectedIndex else { return }
        drafts.remove(at: i)
        selection = drafts.indices.contains(i) ? drafts[i].id : drafts.last?.id
    }

    func addService() {
        guard let i = selectedIndex else { return }
        drafts[i].services.append(ServiceDraft(name: "", local: "", remote: ""))
    }

    func removeService(_ id: UUID) {
        guard let i = selectedIndex else { return }
        drafts[i].services.removeAll { $0.id == id }
    }

    func binding<V>(_ keyPath: WritableKeyPath<MachineDraft, V>, fallback: V) -> Binding<V> {
        Binding(get: { [weak self] in
            guard let self, let i = self.selectedIndex else { return fallback }
            return self.drafts[i][keyPath: keyPath]
        }, set: { [weak self] value in
            guard let self, let i = self.selectedIndex else { return }
            self.drafts[i][keyPath: keyPath] = value
        })
    }

    func serviceBinding(_ id: UUID, _ keyPath: WritableKeyPath<ServiceDraft, String>) -> Binding<String> {
        Binding(get: { [weak self] in
            guard let self, let i = self.selectedIndex,
                  let s = self.drafts[i].services.first(where: { $0.id == id }) else { return "" }
            return s[keyPath: keyPath]
        }, set: { [weak self] value in
            guard let self, let i = self.selectedIndex,
                  let j = self.drafts[i].services.firstIndex(where: { $0.id == id }) else { return }
            self.drafts[i].services[j][keyPath: keyPath] = value
        })
    }
}

extension AppModel {
    /// Saves the editor's machines. Follows a rename of the active machine, refuses to delete it
    /// while connected, and reloads nginx when the active machine's services changed.
    func saveMachines(_ editor: MachinesEditorModel) {
        let list: MachineList
        switch editor.machineList() {
        case .failure(let p):
            editor.problems = p.list
            return
        case .success(let l):
            list = l
        }
        editor.problems = []
        let before = machines
        var newActive = active
        if let active {
            if let renamed = editor.drafts.first(where: { $0.originalName == active }) {
                newActive = renamed.name.trimmingCharacters(in: .whitespaces)
            } else {
                editor.problems = ["Disconnect from \(active) before deleting it."]
                return
            }
        }
        do {
            try store.save(list)
            if newActive != active { try store.setActive(newActive) }
        } catch {
            editor.problems = [error.localizedDescription]
            return
        }
        reload()
        editor.load(list)
        editor.message = "Saved"
        if let name = newActive, before[active ?? ""] != list[name] || name != active {
            reloadNginx()
        }
    }

    func importMachines(_ editor: MachinesEditorModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a machine.json to replace your machines (a backup is kept)."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try store.importMachines(from: url)
            reload()
            editor.load(imported)
            editor.message = "Imported \(imported.count) machines"
            if let active, imported[active] != nil { reloadNginx() }
        } catch {
            showError(title: "Couldn't import \(url.lastPathComponent)", error)
        }
    }

    func exportMachines() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "machine.json"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportMachines(to: url) } catch { showError(title: "Couldn't export", error) }
    }
}

struct MachinesEditorView: View {
    let model: AppModel
    let editor: MachinesEditorModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                machineList.frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
                detail.frame(minWidth: 380)
            }
            Divider()
            bottomBar.padding(12)
        }
        .onAppear { if !editor.hasChanges { editor.load(model.machines) } }
    }

    private var machineList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(editor, \.selection)) {
                ForEach(editor.drafts) { d in
                    HStack {
                        Text(d.name.isEmpty ? "Untitled" : d.name)
                        Spacer()
                        if d.originalName != nil && d.originalName == model.active {
                            Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("Connected")
                        }
                    }
                    .tag(d.id)
                }
            }
            HStack(spacing: 0) {
                Button { editor.addMachine() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    .accessibilityLabel("Add machine")
                Button { editor.removeSelected() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .accessibilityLabel("Remove machine")
                    .disabled(editor.selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless).padding(6)
        }
    }

    @ViewBuilder private var detail: some View {
        if let i = editor.selectedIndex {
            Form {
                TextField("Name", text: editor.binding(\.name, fallback: ""))
                TextField("IP or host", text: editor.binding(\.ip, fallback: ""), prompt: Text("192.168.1.100"))
                Section {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text("Service").font(.caption).foregroundStyle(.secondary)
                            Text("Local port").font(.caption).foregroundStyle(.secondary)
                            Text("Remote port").font(.caption).foregroundStyle(.secondary)
                            Color.clear.frame(width: 16, height: 1)
                        }
                        ForEach(editor.drafts[i].services) { s in
                            GridRow {
                                TextField("Service", text: editor.serviceBinding(s.id, \.name), prompt: Text("user_api"))
                                    .labelsHidden()
                                TextField("Local port", text: editor.serviceBinding(s.id, \.local), prompt: Text("8081"))
                                    .labelsHidden().frame(width: 80)
                                TextField("Remote port", text: editor.serviceBinding(s.id, \.remote), prompt: Text("3000"))
                                    .labelsHidden().frame(width: 80)
                                Button { editor.removeService(s.id) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).accessibilityLabel("Remove \(s.name)")
                            }
                        }
                    }
                    Button("Add service") { editor.addService() }
                } header: {
                    Text("Services")
                } footer: {
                    Text("nginx listens on the local port and forwards to the remote port on this machine.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } else {
            VStack(spacing: 8) {
                Text("No machine selected").foregroundStyle(.secondary)
                Button("Add machine") { editor.addMachine() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !editor.problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(editor.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                .font(.caption)
            }
            HStack {
                Button("Import…") { model.importMachines(editor) }
                Button("Export…") { model.exportMachines() }
                Spacer()
                if let message = editor.message, !editor.hasChanges {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Button("Revert") { editor.load(model.machines) }.disabled(!editor.hasChanges)
                Button("Save") { model.saveMachines(editor) }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.hasChanges)
            }
        }
    }
}
