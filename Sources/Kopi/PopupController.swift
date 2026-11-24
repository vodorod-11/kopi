import AppKit
import Carbon.HIToolbox
import KopiCore
import SwiftUI

/// A panel that takes keyboard focus without activating Kopi, so the app the user was
/// typing in stays frontmost and receives the paste.
final class PopupPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 300, height: 260)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PopupController: NSObject, NSWindowDelegate {
    let model: PopupModel
    private let panel = PopupPanel()
    private let settings: Settings
    private var keyMonitor: Any?
    private var hold = HoldGesture()
    private var holdTimer: Timer?
    /// The app that was frontmost when the popup opened; it gets the paste.
    private(set) var previousApp: NSRunningApplication?

    init(store: ClipStore, settings: Settings) {
        self.settings = settings
        model = PopupModel(store: store)
        super.init()

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        let hosting = NSHostingView(rootView: PopupView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        panel.delegate = self
        panel.setFrameAutosaveName("KopiPopup")
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// The global shortcut was pressed. Opens the popup, or, while its modifiers are still held
    /// since opening, moves one clip down (see `HoldGesture`). Otherwise it closes the popup.
    func shortcutPressed() {
        if isVisible {
            if hold.shortcutPressedAgain() {
                model.moveSelection(by: 1, wrap: true)
            } else {
                hide()
            }
            return
        }
        show()
        guard settings.holdToPaste else { return }
        let started = hold.begin(
            held: HoldGesture.currentModifiers(), shortcut: settings.hotKey.modifierFlags,
            at: ProcessInfo.processInfo.systemUptime)
        guard started else { return }
        let timer = Timer(timeInterval: HoldGesture.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollHold() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func pollHold() {
        let outcome = hold.update(current: HoldGesture.currentModifiers(), at: ProcessInfo.processInfo.systemUptime)
        guard case .released(let paste) = outcome else { return }
        stopHold()
        if paste && isVisible {
            model.perform(.paste)
        }
    }

    private func stopHold() {
        hold.cancel()
        holdTimer?.invalidate()
        holdTimer = nil
    }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }
        model.prepareForShow()
        position()
        panel.makeKeyAndOrderFront(nil)
        model.requestFocus()
        installKeyMonitor()
    }

    func hide() {
        stopHold()
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    // MARK: - Placement

    private func position() {
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        var anchor: NSPoint
        var screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main

        switch settings.popupPosition {
        case .caret:
            if let caret = CaretLocator.caretRect() {
                anchor = NSPoint(x: caret.minX, y: caret.minY - 4)
                screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? screen
            } else {
                anchor = NSPoint(x: mouse.x, y: mouse.y - 4)
            }
        case .cursor:
            anchor = NSPoint(x: mouse.x, y: mouse.y - 4)
        case .center:
            let frame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
            anchor = NSPoint(x: frame.midX - size.width / 2, y: frame.midY + size.height / 2)
        }

        // The anchor is the panel's top-left corner; keep the whole panel on screen.
        guard let visible = screen?.visibleFrame else { return }
        var origin = NSPoint(x: anchor.x, y: anchor.y - size.height)
        if origin.y < visible.minY {
            // No room below the caret: open above it instead.
            origin.y = min(anchor.y + 24, visible.maxY - size.height)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            var result: NSEvent? = event
            MainActor.assumeIsolated { result = self.handle(event) }
            return result
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private static let digitKeys: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9, kVK_ANSI_0: 0,
        kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3, kVK_ANSI_Keypad4: 4,
        kVK_ANSI_Keypad5: 5, kVK_ANSI_Keypad6: 6, kVK_ANSI_Keypad7: 7, kVK_ANSI_Keypad8: 8,
        kVK_ANSI_Keypad9: 9, kVK_ANSI_Keypad0: 0,
    ]

    /// Returns nil when the key was handled; otherwise the event goes on to the search field.
    private func handle(_ event: NSEvent) -> NSEvent? {
        // Leave alerts (group names) and other windows alone.
        guard event.window === panel, panel.attachedSheet == nil else { return event }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)

        // The global shortcut normally never arrives here (the system takes it first), but if it
        // does, treat it the same way so the hold gesture keeps working.
        let shortcut = settings.hotKey
        if code == Int(shortcut.keyCode) && flags == shortcut.modifierFlags {
            shortcutPressed()
            return nil
        }

        switch code {
        case kVK_Escape:
            if !model.query.isEmpty {
                model.query = ""
            } else {
                hide()
            }
            return nil
        case kVK_UpArrow:
            flags.contains(.command) ? model.selectFirst() : model.moveSelection(by: -1)
            return nil
        case kVK_DownArrow:
            flags.contains(.command) ? model.selectLast() : model.moveSelection(by: 1)
            return nil
        case kVK_PageUp:
            model.moveSelection(by: -10)
            return nil
        case kVK_PageDown:
            model.moveSelection(by: 10)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if flags.contains(.shift) {
                model.perform(.pastePlainText)
            } else if flags.contains(.option) {
                model.perform(.copyOnly)
            } else {
                model.perform(.paste)
            }
            return nil
        case kVK_Tab:
            model.cycleFilter(by: flags.contains(.shift) ? -1 : 1)
            return nil
        default:
            break
        }

        guard flags.contains(.command) else { return event }
        if let position = Self.digitKeys[code] {
            model.quickPaste(position: position)
            return nil
        }
        switch code {
        case kVK_Delete, kVK_ForwardDelete:
            model.delete()
            return nil
        case kVK_ANSI_P:
            model.togglePin()
            return nil
        case kVK_ANSI_W:
            hide()
            return nil
        case kVK_ANSI_Comma:
            hide()
            model.onOpenSettings?()
            return nil
        case kVK_ANSI_F, kVK_ANSI_L:
            model.requestFocus()
            return nil
        default:
            // ⌘A, ⌘C, ⌘V, ⌘X, ⌘Z keep working in the search field.
            return event
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Close when the user clicks elsewhere, as Ditto does, but not for our own alerts.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, !self.panel.isKeyWindow, self.panel.attachedSheet == nil else { return }
                if let key = NSApp.keyWindow, key.sheetParent === self.panel { return }
                self.hide()
            }
        }
    }
}
