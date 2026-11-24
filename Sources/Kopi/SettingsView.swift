import AppKit
import KopiCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: Settings
    private let store: ClipStore
    private let status: AppStatus

    init(settings: Settings, store: ClipStore, status: AppStatus) {
        self.settings = settings
        self.store = store
        self.status = status
    }

    func show() {
        if window == nil {
            // The classic macOS settings window: one toolbar button per pane.
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            addPane(to: tabs, "General", "gearshape", GeneralPane(settings: settings, status: status))
            addPane(to: tabs, "History", "clock", HistoryPane(settings: settings, store: store, status: status))
            addPane(to: tabs, "Excluded Apps", "hand.raised", ExcludedAppsPane(settings: settings))
            addPane(to: tabs, "Groups", "folder", GroupsPane(store: store, status: status))
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        status.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func addPane<V: View>(to tabs: NSTabViewController, _ title: String, _ symbol: String, _ pane: V) {
        let controller = NSHostingController(rootView: pane.frame(width: SettingsLayout.width, height: SettingsLayout.height))
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }
}

enum SettingsLayout {
    static let width: CGFloat = 520
    static let height: CGFloat = 400
}

/// Live system state the settings show (permissions, login item, history size).
@MainActor
final class AppStatus: ObservableObject {
    @Published var accessibilityTrusted = Paster.isTrusted
    @Published var clipboardAccess: ClipboardMonitor.Access = .allowed
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var statistics: (clips: Int, bytes: Int) = (0, 0)

    var monitor: ClipboardMonitor?
    var store: ClipStore?
    var onHistoryChanged: (() -> Void)?

    func refresh() {
        accessibilityTrusted = Paster.isTrusted
        if let monitor { clipboardAccess = monitor.refreshAccess() }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if let store, let stats = try? store.statistics() { statistics = stats }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Kopi: launch at login: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct GeneralPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var status: AppStatus

    var body: some View {
        Form {
            Section {
                LabeledContent("Open Kopi with") {
                    ShortcutRecorder(settings: settings)
                }
                Toggle(isOn: $settings.holdToPaste) {
                    Text("Hold \(holdModifiers) and press \(holdKey) again to move down, release to paste")
                    Text("Like Ditto. A quick press just opens the popup.")
                }
                Picker("Show the popup", selection: $settings.popupPosition) {
                    ForEach(PopupPosition.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Move a pasted clip to the top of the list", isOn: $settings.moveToTopOnPaste)
                Toggle("Launch Kopi at login", isOn: Binding(
                    get: { status.launchAtLogin },
                    set: { status.setLaunchAtLogin($0) }))
            }
            Section("Permissions") {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Lets Kopi press ⌘V in the app you were using.",
                    granted: status.accessibilityTrusted,
                    action: { Paster.requestTrust(); Paster.openAccessibilitySettings() })
                PermissionRow(
                    title: "Paste from Other Apps",
                    detail: clipboardDetail,
                    granted: status.clipboardAccess == .allowed,
                    action: { ClipboardAccessHelp.openSettings() })
                Button("Check Again") { status.refresh() }
            }
        }
        .formStyle(.grouped)
        .onAppear { status.refresh() }
    }

    private var holdModifiers: String {
        let display = settings.hotKey.displayString
        let key = KeyboardLayout.name(of: Int(settings.hotKey.keyCode))
        let modifiers = String(display.dropLast(key.count))
        return modifiers.isEmpty ? "the modifier" : modifiers
    }

    private var holdKey: String {
        KeyboardLayout.name(of: Int(settings.hotKey.keyCode))
    }

    private var clipboardDetail: String {
        switch status.clipboardAccess {
        case .allowed: return "Kopi can record what you copy."
        case .notAsked: return "macOS will ask once when you next copy. Then set Kopi to Always Allow."
        case .ask: return "Set to Ask: Kopi records nothing until it is Always Allow (then relaunch Kopi)."
        case .denied: return "Denied: Kopi records nothing. Set it to Always Allow, then relaunch Kopi."
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings", action: action)
            }
        }
    }
}

struct HistoryPane: View {
    @ObservedObject var settings: Settings
    let store: ClipStore
    @ObservedObject var status: AppStatus
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.maxClips, in: 50...50_000, step: 50) {
                    LabeledContent("Keep at most", value: "\(settings.maxClips) clips")
                }
                Stepper(value: $settings.maxAgeDays, in: 0...3_650) {
                    LabeledContent("Delete clips after", value: settings.maxAgeDays == 0 ? "never" : "\(settings.maxAgeDays) days")
                }
                Stepper(value: $settings.maxClipMegabytes, in: 1...500) {
                    LabeledContent("Largest clip", value: "\(settings.maxClipMegabytes) MB")
                }
                Text("Pinned clips and clips in a group are never deleted automatically. A bigger copy keeps only its text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Stored") {
                LabeledContent("History", value: "\(status.statistics.clips) clips, "
                    + ByteCountFormatter.string(fromByteCount: Int64(status.statistics.bytes), countStyle: .file))
                Toggle("Pause recording", isOn: $settings.paused)
                Button("Clear History…", role: .destructive) { confirmClear = true }
            }
        }
        .formStyle(.grouped)
        .onAppear { status.refresh() }
        .confirmationDialog("Clear the clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                _ = try? store.clearHistory()
                status.refresh()
                status.onHistoryChanged?()
            }
        } message: {
            Text("Deletes every clip that is not pinned or in a group. This cannot be undone.")
        }
    }
}

struct ExcludedAppsPane: View {
    @ObservedObject var settings: Settings
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Kopi does not record copies made in these apps. Copies that password managers mark as secret are always skipped.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        if let icon = IconCache.appIcon(bundleID: bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                        Text(Self.appName(bundleID))
                        Spacer()
                        Text(bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(bundleID)
                }
            }
            HStack {
                Button { addApp() } label: { Image(systemName: "plus") }
                Button {
                    if let selection { settings.excludedBundleIDs.removeAll { $0 == selection } }
                    selection = nil
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                Spacer()
                Button("Restore Defaults") { settings.excludedBundleIDs = Settings.defaultExcludedApps }
            }
        }
        .padding()
    }

    /// Names for the default entries, so they read well even when the app is not installed.
    private static let knownNames = [
        "com.apple.keychainaccess": "Keychain Access",
        "com.apple.Passwords": "Passwords",
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden",
        "org.keepassxc.keepassxc": "KeePassXC",
    ]

    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return knownNames[bundleID] ?? bundleID
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier, !settings.excludedBundleIDs.contains(bundleID) {
                settings.excludedBundleIDs.append(bundleID)
            }
        }
    }
}

struct GroupsPane: View {
    let store: ClipStore
    @ObservedObject var status: AppStatus
    @State private var groups: [ClipGroup] = []
    @State private var selection: Int64?
    @State private var newName = ""
    @State private var renaming: ClipGroup?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Groups keep clips you reuse. Clips in a group are never deleted automatically. In the popup, press ⇥ to switch between groups.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(groups) { group in
                    HStack {
                        Image(systemName: "folder")
                        Text(group.name)
                        Spacer()
                        Text(group.clipCount == 1 ? "1 clip" : "\(group.clipCount) clips")
                            .foregroundStyle(.secondary)
                    }
                    .tag(group.id)
                }
            }
            HStack {
                TextField("New group name", text: $newName)
                    .onSubmit(create)
                Button("Add", action: create)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Rename…") {
                    if let group = groups.first(where: { $0.id == selection }) {
                        renameText = group.name
                        renaming = group
                    }
                }
                .disabled(selection == nil)
                Button("Delete", role: .destructive) {
                    if let selection { change { try store.deleteGroup(selection) } }
                    selection = nil
                }
                .disabled(selection == nil)
            }
        }
        .padding()
        .onAppear(perform: load)
        .alert("Rename Group", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if let group = renaming, !name.isEmpty { change { try store.renameGroup(group.id, to: name) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func load() {
        groups = (try? store.groups()) ?? []
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        change { try store.createGroup(named: name) }
        newName = ""
    }

    private func change(_ body: () throws -> Void) {
        do { try body() } catch { NSLog("Kopi: group change failed: \(error)") }
        load()
        status.onHistoryChanged?()
    }
}

private struct ShortcutRecorder: View {
    @ObservedObject var settings: Settings
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(settings.isRecordingShortcut ? "Type the new shortcut…" : settings.hotKey.displayString) {
                settings.isRecordingShortcut ? stop() : start()
            }
            .frame(minWidth: 140)
            if settings.hotKey != .default && !settings.isRecordingShortcut {
                Button("Reset") { settings.hotKey = .default }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        settings.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                MainActor.assumeIsolated { stop() }
                return nil
            }
            if let combo = KeyCombo(event: event) {
                MainActor.assumeIsolated {
                    settings.hotKey = combo
                    stop()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if settings.isRecordingShortcut { settings.isRecordingShortcut = false }
    }
}

enum ClipboardAccessHelp {
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
            NSWorkspace.shared.open(url)
        }
    }
}
