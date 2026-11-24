import AppKit
import KopiCore

enum PasteMode {
    /// Put the clip on the clipboard and press ⌘V in the previous app.
    case paste
    /// Same, as plain text.
    case pastePlainText
    /// Only put the clip on the clipboard.
    case copyOnly
}

/// State of the history popup.
@MainActor
final class PopupModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { reload() } }
    }
    @Published var filter: ClipFilter = .all {
        didSet { if filter != oldValue { reload() } }
    }
    @Published private(set) var clips: [ClipSummary] = []
    @Published private(set) var groups: [ClipGroup] = []
    @Published var selectedID: Int64?
    /// Incremented to ask the view to focus the search field.
    @Published private(set) var focusRequest = 0
    /// Set when the history list should scroll to the selection.
    @Published private(set) var scrollRequest = 0
    @Published var notice: String?

    let store: ClipStore
    var onPerform: ((ClipSummary, PasteMode) -> Void)?
    var onClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init(store: ClipStore) {
        self.store = store
    }

    var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return clips.firstIndex { $0.id == selectedID }
    }

    var selectedClip: ClipSummary? {
        selectedIndex.map { clips[$0] }
    }

    func groupName(_ id: Int64?) -> String? {
        guard let id else { return nil }
        return groups.first { $0.id == id }?.name
    }

    /// Fresh state each time the popup opens, like Ditto: empty search, newest clip selected.
    func prepareForShow() {
        notice = nil
        if !query.isEmpty { query = "" }
        if case .group(let id) = filter, !groups.contains(where: { $0.id == id }) { filter = .all }
        reload()
        selectedID = clips.first?.id
        scrollRequest += 1
        focusRequest += 1
    }

    func reload() {
        do {
            groups = try store.groups()
            if case .group(let id) = filter, !groups.contains(where: { $0.id == id }) {
                filter = .all
                return
            }
            clips = try store.clips(filter: filter, query: query)
        } catch {
            clips = []
            notice = "Could not read the history: \(error)"
        }
        if selectedIndex == nil {
            selectedID = clips.first?.id
            scrollRequest += 1
        }
    }

    // MARK: - Navigation

    /// With `wrap`, moving past the last clip goes back to the first (for the hold gesture).
    func moveSelection(by delta: Int, wrap: Bool = false) {
        guard !clips.isEmpty else { return }
        let current = selectedIndex ?? -1
        let next = wrap
            ? ((current + delta) % clips.count + clips.count) % clips.count
            : min(max(current + delta, 0), clips.count - 1)
        selectedID = clips[next].id
        scrollRequest += 1
    }

    func requestFocus() {
        focusRequest += 1
    }

    func selectFirst() {
        selectedID = clips.first?.id
        scrollRequest += 1
    }

    func selectLast() {
        selectedID = clips.last?.id
        scrollRequest += 1
    }

    /// Tab / ⇧Tab: All → Pinned → each group → All.
    func cycleFilter(by delta: Int) {
        let filters: [ClipFilter] = [.all, .pinned] + groups.map { .group($0.id) }
        let current = filters.firstIndex(of: filter) ?? 0
        filter = filters[(current + delta + filters.count) % filters.count]
        selectFirst()
    }

    // MARK: - Actions

    func perform(_ mode: PasteMode) {
        guard let clip = selectedClip else { return }
        onPerform?(clip, mode)
    }

    func perform(_ clip: ClipSummary, _ mode: PasteMode) {
        selectedID = clip.id
        onPerform?(clip, mode)
    }

    /// ⌘1…⌘9 paste the first nine clips of the list, ⌘0 the tenth.
    func quickPaste(position: Int) {
        let index = position == 0 ? 9 : position - 1
        guard clips.indices.contains(index) else { return }
        perform(clips[index], .paste)
    }

    func togglePin(_ clip: ClipSummary? = nil) {
        guard let clip = clip ?? selectedClip else { return }
        attempt { try store.setPinned(clip.id, !clip.pinned) }
    }

    func delete(_ clip: ClipSummary? = nil) {
        guard let clip = clip ?? selectedClip, let index = clips.firstIndex(of: clip) else { return }
        attempt { try store.delete(clip.id) }
        if !clips.isEmpty {
            selectedID = clips[min(index, clips.count - 1)].id
        }
    }

    func move(_ clip: ClipSummary, toGroup groupID: Int64?) {
        attempt { try store.setGroup(clip.id, groupID) }
    }

    func createGroup(named name: String, adding clip: ClipSummary? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        attempt {
            let id = try store.createGroup(named: trimmed)
            if let clip { try store.setGroup(clip.id, id) }
        }
    }

    func renameGroup(_ group: ClipGroup, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        attempt { try store.renameGroup(group.id, to: trimmed) }
    }

    func deleteGroup(_ group: ClipGroup) {
        attempt { try store.deleteGroup(group.id) }
    }

    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            notice = "\(error)"
        }
        reload()
    }

    // MARK: - Images and icons

    private let thumbnails = NSCache<NSNumber, NSImage>()

    func thumbnail(for clip: ClipSummary) -> NSImage? {
        guard clip.hasThumbnail else { return nil }
        let key = NSNumber(value: clip.id)
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let data = try? store.thumbnail(id: clip.id), let image = NSImage(data: data) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }
}

/// App and file icons, cached.
@MainActor
enum IconCache {
    private static var appIcons: [String: NSImage] = [:]

    static func appIcon(bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let icon = appIcons[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIcons[bundleID] = icon
        return icon
    }
}
