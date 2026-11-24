import AppKit
import KopiCore

/// Watches the general pasteboard. macOS has no change notification, so it polls the change
/// count (cheap; reading the change count never triggers the pasteboard privacy alert).
@MainActor
final class ClipboardMonitor {
    struct Capture {
        var content: ClipContent
        var plainText: String?
        var sourceBundleID: String?
        var sourceName: String?
    }

    enum Access: Equatable {
        /// Kopi can read copies without macOS asking.
        case allowed
        /// macOS has not asked yet; the next read shows the system alert once.
        case notAsked
        /// "Paste from Other Apps" is set to Ask: every read would show an alert, so Kopi does not read.
        case ask
        /// "Paste from Other Apps" is set to Deny.
        case denied
    }

    var onCapture: ((Capture) -> Void)?
    var onAccessChange: ((Access) -> Void)?

    private(set) var access: Access = .allowed
    private let pasteboard = NSPasteboard.general
    private let settings: Settings
    private var lastChangeCount: Int
    private var timer: Timer?

    init(settings: Settings) {
        self.settings = settings
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        lastChangeCount = pasteboard.changeCount
        refreshAccess()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Call after Kopi writes to the pasteboard so its own write is not recorded again.
    func skipCurrentContents() {
        lastChangeCount = pasteboard.changeCount
    }

    @discardableResult
    func refreshAccess() -> Access {
        var newAccess = Access.allowed
        if #available(macOS 15.4, *) {
            switch pasteboard.accessBehavior {
            case .alwaysAllow: newAccess = .allowed
            case .ask: newAccess = .ask
            case .alwaysDeny: newAccess = .denied
            default: newAccess = .notAsked
            }
        }
        if newAccess != access {
            access = newAccess
            onAccessChange?(newAccess)
        }
        return newAccess
    }

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard !settings.paused else { return }

        let access = refreshAccess()
        guard access == .allowed || access == .notAsked else { return }

        let app = NSWorkspace.shared.frontmostApplication
        if let bundleID = app?.bundleIdentifier, settings.excludedBundleIDs.contains(bundleID) { return }

        switch PasteboardIO.read(pasteboard, maxBytes: settings.maxClipBytes) {
        case .content(let content):
            let capture = Capture(
                content: content,
                plainText: PasteboardIO.plainText(of: content),
                sourceBundleID: app?.bundleIdentifier,
                sourceName: app?.localizedName)
            onCapture?(capture)
        case .ignored:
            break
        case .tooLarge(let bytes):
            NSLog("Kopi: skipped a %d MB copy (limit %d MB)", bytes / 1_048_576, settings.maxClipMegabytes)
        }
        // The first read may have changed the state (the system alert moves it to "Ask").
        refreshAccess()
    }
}
