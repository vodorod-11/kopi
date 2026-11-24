import AppKit

// A menu-bar app: no Dock icon, no main window (LSUIElement in Info.plist does the same for the bundle).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
