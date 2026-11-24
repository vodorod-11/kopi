import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Sends ⌘V to the frontmost app. Needs the Accessibility permission.
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to System Settings › Accessibility.
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func pasteCommandV() {
        let vKey = KeyboardLayout.keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keep the user's own key presses from mixing into the synthetic ⌘V.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}

/// Finds the text cursor of the focused app through the Accessibility API.
enum CaretLocator {
    /// The caret rectangle in Cocoa screen coordinates (origin bottom-left), if the app exposes it.
    static func caretRect() -> NSRect? {
        guard Paster.isTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        guard let focused: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) else { return nil }
        guard let rangeValue: AXValue = attribute(focused, kAXSelectedTextRangeAttribute) else { return nil }

        var boundsRef: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            focused, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsRef)
        guard status == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        guard rect.width >= 0, rect.height > 0, rect.origin != .zero else { return nil }

        // Accessibility uses top-left origin on the primary screen; Cocoa uses bottom-left.
        guard let primary = NSScreen.screens.first else { return nil }
        let flipped = NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(flipped) }) else { return nil }
        return flipped
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }
}
