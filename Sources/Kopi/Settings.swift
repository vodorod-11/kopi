import AppKit
import Combine

enum PopupPosition: String, CaseIterable, Identifiable {
    case caret
    case cursor
    case center

    var id: String { rawValue }

    var label: String {
        switch self {
        case .caret: return "At the text cursor (falls back to the mouse)"
        case .cursor: return "At the mouse pointer"
        case .center: return "Center of the screen"
        }
    }
}

/// User preferences, stored in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var hotKey: KeyCombo { didSet { save(hotKey, "hotKey") } }
    @Published var popupPosition: PopupPosition { didSet { defaults.set(popupPosition.rawValue, forKey: "popupPosition") } }
    @Published var moveToTopOnPaste: Bool { didSet { defaults.set(moveToTopOnPaste, forKey: "moveToTopOnPaste") } }
    @Published var maxClips: Int { didSet { defaults.set(maxClips, forKey: "maxClips") } }
    @Published var maxAgeDays: Int { didSet { defaults.set(maxAgeDays, forKey: "maxAgeDays") } }
    @Published var maxClipMegabytes: Int { didSet { defaults.set(maxClipMegabytes, forKey: "maxClipMegabytes") } }
    @Published var excludedBundleIDs: [String] { didSet { defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs") } }
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: "paused") } }
    /// Ditto's gesture: hold the shortcut's modifier, press its key again to move down, release to paste.
    @Published var holdToPaste: Bool { didSet { defaults.set(holdToPaste, forKey: "holdToPaste") } }

    /// True while the shortcut recorder listens, so the global shortcut does not fire.
    @Published var isRecordingShortcut = false

    static let defaultExcludedApps = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
    ]

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "popupPosition": PopupPosition.caret.rawValue,
            "moveToTopOnPaste": true,
            "maxClips": 1_000,
            "maxAgeDays": 0,
            "maxClipMegabytes": 20,
            "excludedBundleIDs": Self.defaultExcludedApps,
            "paused": false,
            "holdToPaste": true,
        ])
        hotKey = (defaults.data(forKey: "hotKey")).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .default
        popupPosition = PopupPosition(rawValue: defaults.string(forKey: "popupPosition") ?? "") ?? .caret
        moveToTopOnPaste = defaults.bool(forKey: "moveToTopOnPaste")
        maxClips = defaults.integer(forKey: "maxClips")
        maxAgeDays = defaults.integer(forKey: "maxAgeDays")
        maxClipMegabytes = defaults.integer(forKey: "maxClipMegabytes")
        excludedBundleIDs = defaults.stringArray(forKey: "excludedBundleIDs") ?? Self.defaultExcludedApps
        paused = defaults.bool(forKey: "paused")
        holdToPaste = defaults.bool(forKey: "holdToPaste")
    }

    var maxAge: TimeInterval { TimeInterval(max(maxAgeDays, 0)) * 86_400 }
    var maxClipBytes: Int { max(maxClipMegabytes, 1) * 1_048_576 }

    private func save(_ combo: KeyCombo, _ key: String) {
        if let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: key)
        }
    }
}
