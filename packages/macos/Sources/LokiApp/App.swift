import AppKit
import Carbon.HIToolbox
import LokiCore
import SwiftUI

@main
enum Main {
    @MainActor static var delegate: AppDelegate?  // NSApplication.delegate is weak

    @MainActor static func main() {
        let app = NSApplication.shared
        delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    let settingsUI = SettingsUI()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    var settingsWindow: NSWindow?
    var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingController(rootView: PanelView(model: model, ui: PanelUI()))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        item.button?.target = self
        item.button?.action = #selector(toggle)
        model.onChange = { [weak self] in self?.updateTitle() }
        model.openSettings = { [weak self] tab in self?.showSettings(tab) }
        model.makeDataFolderPrivate()
        model.reload()
        model.startLoop()
        model.startUpdateChecks()
        registerHotKey()
        Task {
            await model.refreshSetup()
            // First launch on a new Mac: walk the user through what's missing.
            if model.setupNeedsAttention || model.machines.isEmpty { showSettings(.setup) }
        }
    }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item.button else { return }
        model.reload()
        model.readLog()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func showSettings(_ tab: SettingsTab) {
        popover.performClose(nil)
        settingsUI.tab = tab
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, ui: settingsUI)))
            window.title = "Loki Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 720, height: 520))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        if tab == .machines && !settingsUI.machines.hasChanges { settingsUI.machines.load(model.machineFile) }
        // A menu bar app has no Dock icon; show one while a window is open so it can be found with ⌘Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// "● aws_machine 7/8": green all up, orange some slow/down, red all down, gray idle.
    func updateTitle() {
        var dot = NSColor.systemGray
        var text = " Loki"
        if let name = model.active, let machine = model.activeMachine {
            let c = model.counts
            let up = c.up + c.slow
            let total = machine.ports.count
            if !model.status.isEmpty {
                dot = up == 0 && total > 0 ? .systemRed : (c.down > 0 || c.slow > 0) ? .systemOrange : .systemGreen
            }
            let short = name.count > 16 ? String(name.prefix(15)) + "…" : name
            text = " \(short) \(model.status.isEmpty ? "…" : "\(up)/\(total)")"
        }
        if model.setupNeedsAttention { dot = .systemRed }
        let title = NSMutableAttributedString(string: "●", attributes: [.foregroundColor: dot, .font: NSFont.systemFont(ofSize: 11)])
        title.append(NSAttributedString(string: text, attributes: [.font: NSFont.menuBarFont(ofSize: 0)]))
        item.button?.attributedTitle = title
        item.button?.setAccessibilityLabel("Loki: \(text.trimmingCharacters(in: .whitespaces))")
    }

    /// ⌥⌘L toggles the panel from anywhere. Carbon is still the only API for a
    /// global hotkey that needs no Accessibility permission.
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.toggle() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | optionKey),
                            EventHotKeyID(signature: OSType(0x4C4F_4B49), id: 1),  // "LOKI"
                            GetApplicationEventTarget(), 0, &hotKey)
    }
}
