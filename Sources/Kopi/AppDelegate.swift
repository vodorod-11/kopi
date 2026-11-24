import AppKit
import Combine
import KopiCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let status = AppStatus()
    private var store: ClipStore!
    private var monitor: ClipboardMonitor!
    private var popup: PopupController!
    private var settingsWindow: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private var hotKeyID: UInt32?
    private var cancellables: Set<AnyCancellable> = []
    private var trimTimer: Timer?
    private var explainedAccessibility = false
    private var explainedClipboardAccess = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if anotherInstanceIsRunning() {
            NSApp.terminate(nil)
            return
        }
        do {
            store = try ClipStore(path: Self.databaseURL().path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Kopi cannot open its history"
            alert.informativeText = "\(Self.databaseURL().path)\n\n\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        trim()

        popup = PopupController(store: store, settings: settings)
        popup.model.onPerform = { [weak self] clip, mode in self?.perform(clip, mode: mode) }
        popup.model.onOpenSettings = { [weak self] in self?.showSettings() }

        monitor = ClipboardMonitor(settings: settings)
        monitor.onCapture = { [weak self] capture in self?.save(capture) }
        monitor.onAccessChange = { [weak self] access in self?.clipboardAccessChanged(access) }

        status.monitor = monitor
        status.store = store
        status.onHistoryChanged = { [weak self] in self?.popup.model.reload() }
        settingsWindow = SettingsWindowController(settings: settings, store: store, status: status)

        setUpStatusItem()
        monitor.start()
        registerHotKey()
        observeSettings()

        let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trim() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trimTimer = timer

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            showWelcome()
        }
    }

    static func databaseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["KOPI_DATABASE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kopi", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("kopi.sqlite")
    }

    private func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != me }
    }

    // MARK: - Capture

    private func save(_ capture: ClipboardMonitor.Capture) {
        do {
            try store.insert(
                capture.content, plainText: capture.plainText,
                sourceBundleID: capture.sourceBundleID, sourceName: capture.sourceName)
            try store.trim(maxCount: settings.maxClips, maxAge: settings.maxAge)
        } catch {
            NSLog("Kopi: could not store a clip: \(error)")
        }
        if popup.isVisible { popup.model.reload() }
    }

    private func trim() {
        do {
            try store.trim(maxCount: settings.maxClips, maxAge: settings.maxAge)
        } catch {
            NSLog("Kopi: trim failed: \(error)")
        }
    }

    // MARK: - Paste

    private func perform(_ clip: ClipSummary, mode: PasteMode) {
        guard let content = try? store.content(id: clip.id) else {
            popup.model.notice = "That clip has no data any more."
            return
        }
        let target = popup.previousApp
        popup.hide()

        PasteboardIO.write(content, plainTextOnly: mode == .pastePlainText, to: .general)
        monitor.skipCurrentContents()
        try? store.markUsed(clip.id, moveToTop: settings.moveToTopOnPaste)

        guard mode != .copyOnly else { return }
        guard Paster.isTrusted else {
            explainAccessibility()
            return
        }
        if let target, NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.activate()
        }
        // Give the target app a moment to take keyboard focus back from the popup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Paster.pasteCommandV()
        }
    }

    private func explainAccessibility() {
        guard !explainedAccessibility else { return }
        explainedAccessibility = true
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Allow Kopi to paste for you"
        alert.informativeText = """
            The clip is on the clipboard, so ⌘V pastes it now.

            To paste straight into the app you were using, Kopi needs Accessibility access: \
            System Settings › Privacy & Security › Accessibility › Kopi.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            Paster.requestTrust()
            Paster.openAccessibilitySettings()
        }
    }

    // MARK: - Clipboard access (macOS 15.4+)

    private func clipboardAccessChanged(_ access: ClipboardMonitor.Access) {
        status.clipboardAccess = access
        updateStatusIcon()
        if access == .ask || access == .denied, !explainedClipboardAccess {
            explainedClipboardAccess = true
            explainClipboardAccess()
        }
    }

    @objc private func explainClipboardAccess() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Let Kopi see what you copy"
        alert.informativeText = """
            macOS asks before an app reads what other apps copied. Kopi records nothing until it is allowed.

            In System Settings › Privacy & Security › Paste from Other Apps, set Kopi to Always Allow, \
            then relaunch Kopi (macOS applies the change after a relaunch).
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch Kopi")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: ClipboardAccessHelp.openSettings()
        case .alertSecondButtonReturn: relaunch()
        default: break
        }
    }

    @objc private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Hot key and settings

    private func registerHotKey() {
        if let hotKeyID {
            HotKeyCenter.shared.unregister(hotKeyID)
            self.hotKeyID = nil
        }
        guard !settings.isRecordingShortcut else { return }
        hotKeyID = HotKeyCenter.shared.register(settings.hotKey) { [weak self] in
            self?.popup.shortcutPressed()
        }
        if hotKeyID == nil {
            NSLog("Kopi: could not register the shortcut \(settings.hotKey.displayString)")
        }
    }

    private func observeSettings() {
        // @Published fires before the value is stored, so act on the next run-loop turn.
        settings.$hotKey.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotKey() } }
            .store(in: &cancellables)
        settings.$isRecordingShortcut.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotKey() } }
            .store(in: &cancellables)
        settings.$paused.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusIcon() } }
            .store(in: &cancellables)
        settings.$maxClips.dropFirst().combineLatest(settings.$maxAgeDays)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.trim(); self?.status.refresh() }
            .store(in: &cancellables)
    }

    private func showSettings() {
        popup.hide()
        settingsWindow.show()
    }

    private func showWelcome() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Kopi is running"
        alert.informativeText = """
            Kopi lives in the menu bar and keeps what you copy.

            Press \(settings.hotKey.displayString) anywhere to open your history, type to search, \
            and press ↩ to paste. Or, like in Ditto, keep the modifier down, press the key again to \
            move down the list, and let go to paste. You can change the shortcut in Settings.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Settings")
        if alert.runModal() == .alertSecondButtonReturn {
            showSettings()
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let needsAccess = monitor.map { $0.access == .ask || $0.access == .denied } ?? false
        let symbol = settings.paused ? "pause.circle" : (needsAccess ? "exclamationmark.triangle" : "list.clipboard")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Kopi")
        image?.isTemplate = true
        button.image = image
        button.toolTip = settings.paused ? "Kopi (paused)" : "Kopi"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let show = NSMenuItem(title: "Show Clipboard History", action: #selector(showPopup), keyEquivalent: "")
        let combo = settings.hotKey
        let key = KeyboardLayout.name(of: Int(combo.keyCode))
        if key.count == 1 {
            show.keyEquivalent = key.lowercased()
            show.keyEquivalentModifierMask = combo.modifierFlags
        }
        menu.addItem(show)

        if let monitor, monitor.access == .ask || monitor.access == .denied {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "⚠︎ Kopi cannot read the clipboard…", action: #selector(explainClipboardAccess), keyEquivalent: ""))
        }

        menu.addItem(.separator())
        let pause = NSMenuItem(title: settings.paused ? "Resume Recording" : "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(pause)
        menu.addItem(NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "About Kopi", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Kopi", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
    }

    @objc private func showPopup() {
        // Let the menu close first so the previous app is frontmost again.
        DispatchQueue.main.async { [weak self] in self?.popup.show() }
    }

    @objc private func togglePause() {
        settings.paused.toggle()
    }

    @objc private func clearHistory() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Clear the clipboard history?"
        alert.informativeText = "Deletes every clip that is not pinned or in a group. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            _ = try? store.clearHistory()
            popup.model.reload()
            status.refresh()
        }
    }

    @objc private func openSettings() {
        showSettings()
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: """
                A clipboard history for macOS, inspired by Ditto for Windows.
                https://github.com/vodorod-11/kopi
                """),
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
