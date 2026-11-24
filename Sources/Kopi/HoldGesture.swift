import AppKit

/// Ditto's "hold the modifier" gesture, like ⌘⇥ in macOS:
///
/// 1. The shortcut (say ⌃Q) opens the popup. The shortcut's modifiers that are still down are remembered.
/// 2. While they stay down, each further press of the shortcut moves the selection one clip down.
/// 3. Releasing them pastes the selected clip, if the selection was moved or they were held longer
///    than `pasteAfterHolding`. A quick tap leaves the popup open for searching.
///
/// Once the modifiers are up, the shortcut closes the popup again.
struct HoldGesture {
    /// Ditto checks every 50 ms and pastes after 20 checks without a move (about one second).
    static let pollInterval: TimeInterval = 0.05
    static let pasteAfterHolding: TimeInterval = 1.0

    enum Outcome: Equatable {
        case stillHeld
        case released(paste: Bool)
    }

    private(set) var heldModifiers: NSEvent.ModifierFlags = []
    private(set) var movedSelection = false
    private var start: TimeInterval = 0

    var isActive: Bool { !heldModifiers.isEmpty }

    /// Call when the shortcut opened the popup. Returns true when there is something to watch.
    @discardableResult
    mutating func begin(held: NSEvent.ModifierFlags, shortcut: NSEvent.ModifierFlags, at time: TimeInterval) -> Bool {
        heldModifiers = held.intersection(shortcut).intersection([.command, .option, .control, .shift])
        movedSelection = false
        start = time
        return isActive
    }

    /// Call when the shortcut is pressed while the popup is open.
    /// Returns true to move the selection down, false to close the popup.
    mutating func shortcutPressedAgain() -> Bool {
        guard isActive else { return false }
        movedSelection = true
        return true
    }

    /// Call on every poll with the modifiers that are down now.
    mutating func update(current: NSEvent.ModifierFlags, at time: TimeInterval) -> Outcome {
        guard isActive else { return .released(paste: false) }
        // Like Ditto, wait until every remembered modifier is up.
        if !current.intersection(heldModifiers).isEmpty { return .stillHeld }
        let paste = movedSelection || time - start > Self.pasteAfterHolding
        cancel()
        return .released(paste: paste)
    }

    mutating func cancel() {
        heldModifiers = []
        movedSelection = false
    }

    /// The modifier keys that are physically down right now, whichever app is active.
    static func currentModifiers() -> NSEvent.ModifierFlags {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var modifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        return modifiers
    }
}
