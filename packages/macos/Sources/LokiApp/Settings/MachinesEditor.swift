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
    /// Its own services; kept but unused while `shared` is on, so turning it off again loses nothing.
    var services: [ServiceDraft]
    /// One of machine.json's "containers": it gets the shared services instead of its own.
    var shared: Bool
    /// Name in machine.json when loaded; nil for a new machine. Used to follow renames of the active machine.
    var originalName: String?
}

/// Editable copy of machine.json. Nothing is written until Save.
@MainActor @Observable
final class MachinesEditorModel {
    var drafts: [MachineDraft] = []
    /// machine.json's "services": what every machine with `shared` on gets.
    var shared: [ServiceDraft] = []
    var selection: UUID?
    var problems: [String] = []
    var message: String?
    private var saved: [MachineDraft] = []
    private var savedShared: [ServiceDraft] = []

    var hasChanges: Bool { drafts != saved || shared != savedShared }
    var selectedIndex: Int? { drafts.firstIndex { $0.id == selection } }

    /// The selected machine's services: its own, or the shared ones.
    var selectedServices: [ServiceDraft] {
        get { selectedIndex.map { drafts[$0].shared ? shared : drafts[$0].services } ?? [] }
        set {
            guard let i = selectedIndex else { return }
            if drafts[i].shared { shared = newValue } else { drafts[i].services = newValue }
        }
    }

    func load(_ file: MachineFile) {
        drafts = file.all.sorted { $0.key < $1.key }.map { name, machine in
            let own = file.machines[name] != nil
            return MachineDraft(name: name, ip: machine.ip, services: own ? Self.drafts(machine.services) : [],
                                shared: !own, originalName: name)
        }
        shared = Self.drafts(file.services)
        saved = drafts
        savedShared = shared
        if selectedIndex == nil { selection = drafts.first?.id }
        problems = []
    }

    private static func drafts(_ services: [String: Ports]) -> [ServiceDraft] {
        services.sorted { $0.key < $1.key }.map { name, p in
            ServiceDraft(name: name, local: p.local.map(String.init) ?? "", remote: p.remote.map(String.init) ?? "")
        }
    }

    /// The drafts as machine.json, or the reasons they can't be.
    func machineFile() -> Result<MachineFile, Problems> {
        var problems: [String] = []
        var file = MachineFile(services: Self.services(shared, of: "Shared services", problems: &problems))
        for d in drafts {
            let name = d.name.trimmingCharacters(in: .whitespaces)
            let ip = d.ip.trimmingCharacters(in: .whitespaces)
            if file.machines[name] != nil || file.containers[name] != nil {
                problems.append("Two machines are called “\(name)”.")
            } else if d.shared {
                file.containers[name] = ip
            } else {
                file.machines[name] = Machine(ip: ip, services: Self.services(d.services, of: name, problems: &problems))
            }
        }
        problems += validate(file).map(\.description)
        return problems.isEmpty ? .success(file) : .failure(Problems(list: problems))
    }

    private static func services(_ drafts: [ServiceDraft], of owner: String, problems: inout [String]) -> [String: Ports] {
        var services: [String: Ports] = [:]
        for s in drafts {
            let name = s.name.trimmingCharacters(in: .whitespaces)
            if services[name] != nil { problems.append("\(owner): two services are called “\(name)”.") }
            let local = Int(s.local.trimmingCharacters(in: .whitespaces))
            let remote = Int(s.remote.trimmingCharacters(in: .whitespaces))
            if local == nil && !s.local.isEmpty { problems.append("\(owner) → \(name): local port “\(s.local)” isn't a number.") }
            if remote == nil && !s.remote.isEmpty { problems.append("\(owner) → \(name): remote port “\(s.remote)” isn't a number.") }
            services[name] = Ports(local: local, remote: remote)
        }
        return services
    }

    struct Problems: Error { let list: [String] }

    /// A new machine gets the shared services when there are some, otherwise a service of its own.
    func addMachine() {
        var n = 1
        while drafts.contains(where: { $0.name == "machine_\(n)" }) { n += 1 }
        let d = MachineDraft(name: "machine_\(n)", ip: "",
                             services: shared.isEmpty ? [ServiceDraft(name: "web", local: "", remote: "")] : [],
                             shared: !shared.isEmpty, originalName: nil)
        drafts.append(d)
        selection = d.id
    }

    /// Switches the selected machine between the shared services and its own. Whichever list it
    /// switches to starts as a copy of the other when empty: the first machine to share its services
    /// makes them the shared ones, and one leaving the shared services keeps them to edit.
    func setShared(_ on: Bool) {
        guard let i = selectedIndex, drafts[i].shared != on else { return }
        if on && shared.isEmpty { shared = drafts[i].services }
        if !on && drafts[i].services.isEmpty { drafts[i].services = shared }
        drafts[i].shared = on
    }

    func removeSelected() {
        guard let i = selectedIndex else { return }
        drafts.remove(at: i)
        selection = drafts.indices.contains(i) ? drafts[i].id : drafts.last?.id
    }

    func addService() {
        selectedServices.append(ServiceDraft(name: "", local: "", remote: ""))
    }

    func removeService(_ id: UUID) {
        selectedServices.removeAll { $0.id == id }
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
            self?.selectedServices.first { $0.id == id }?[keyPath: keyPath] ?? ""
        }, set: { [weak self] value in
            guard let self, let j = self.selectedServices.firstIndex(where: { $0.id == id }) else { return }
            self.selectedServices[j][keyPath: keyPath] = value
        })
    }
}

extension AppModel {
    /// Saves the editor's machines. Follows a rename of the active machine, refuses to delete it
    /// while connected, and reloads nginx when the active machine's services changed.
    func saveMachines(_ editor: MachinesEditorModel) {
        let file: MachineFile
        switch editor.machineFile() {
        case .failure(let p):
            editor.problems = p.list
            return
        case .success(let f):
            file = f
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
            try store.save(file)
            if newActive != active { try store.setActive(newActive) }
        } catch {
            editor.problems = [error.localizedDescription]
            return
        }
        reload()
        editor.load(file)
        editor.message = "Saved"
        if let name = newActive, before[active ?? ""] != file.all[name] || name != active {
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
            editor.message = "Imported \(imported.all.count) machines"
            if let active, imported.all[active] != nil { reloadNginx() }
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
        .onAppear { if !editor.hasChanges { editor.load(model.machineFile) } }
    }

    private var machineList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(editor, \.selection)) {
                ForEach(editor.drafts) { d in
                    HStack {
                        Text(d.name.isEmpty ? "Untitled" : d.name)
                        Spacer()
                        if d.shared {
                            Image(systemName: "link").font(.caption).foregroundStyle(.secondary)
                                .help("Uses the shared services").accessibilityLabel("Uses the shared services")
                        }
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
                Toggle("Use shared services", isOn: Binding(get: { editor.selectedIndex.map { editor.drafts[$0].shared } ?? false },
                                                            set: { editor.setShared($0) }))
                Section {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text("Service").font(.caption).foregroundStyle(.secondary)
                            Text("Local port").font(.caption).foregroundStyle(.secondary)
                            Text("Remote port").font(.caption).foregroundStyle(.secondary)
                            Color.clear.frame(width: 16, height: 1)
                        }
                        ForEach(editor.selectedServices) { s in
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
                    Text(editor.drafts[i].shared ? "Shared services" : "Services")
                } footer: {
                    Text(footer(editor.drafts[i]))
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

    private func footer(_ d: MachineDraft) -> String {
        let forward = "nginx listens on the local port and forwards to the remote port on this machine."
        guard d.shared else { return forward }
        let users = editor.drafts.filter(\.shared).map { $0.name.isEmpty ? "Untitled" : $0.name }
        return "\(forward) Every machine using shared services gets these, so changes apply to \(users.joined(separator: ", "))."
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
                Button("Revert") { editor.load(model.machineFile) }.disabled(!editor.hasChanges)
                Button("Save") { model.saveMachines(editor) }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.hasChanges)
            }
        }
    }
}
