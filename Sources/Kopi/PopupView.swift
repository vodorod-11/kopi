import KopiCore
import SwiftUI

struct PopupView: View {
    @ObservedObject var model: PopupModel
    @FocusState private var searchFocused: Bool
    @State private var groupPrompt: GroupPrompt?
    @State private var groupName = ""

    var body: some View {
        VStack(spacing: 0) {
            searchField
            FilterBar(model: model, onNewGroup: { startNewGroup(adding: nil) }, onRename: startRename)
            Divider()
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            if model.clips.isEmpty {
                emptyState
            } else {
                clipList
            }
            Divider()
            footer
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { _, _ in searchFocused = true }
        .alert(groupPrompt?.title ?? "", isPresented: Binding(
            get: { groupPrompt != nil },
            set: { if !$0 { groupPrompt = nil } }
        )) {
            TextField("Name", text: $groupName)
            Button(groupPrompt?.confirmLabel ?? "OK") { commitGroupPrompt() }
            Button("Cancel", role: .cancel) { groupPrompt = nil }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search clips", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
            Button {
                model.onOpenSettings?()
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var clipList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                        ClipRow(
                            clip: clip,
                            position: index,
                            isSelected: clip.id == model.selectedID,
                            groupName: model.filter == .all ? model.groupName(clip.groupID) : nil,
                            thumbnail: model.thumbnail(for: clip))
                            .id(clip.id)
                            .onTapGesture(count: 2) { model.perform(clip, .paste) }
                            .simultaneousGesture(TapGesture().onEnded { model.selectedID = clip.id })
                            .contextMenu { contextMenu(for: clip) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .onChange(of: model.scrollRequest) { _, _ in
                if let id = model.selectedID {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for clip: ClipSummary) -> some View {
        Button("Paste") { model.perform(clip, .paste) }
        Button("Paste as Plain Text") { model.perform(clip, .pastePlainText) }
        Button("Copy to Clipboard") { model.perform(clip, .copyOnly) }
        Divider()
        Button(clip.pinned ? "Unpin" : "Pin") { model.togglePin(clip) }
        Menu("Move to Group") {
            ForEach(model.groups) { group in
                Button(group.name) { model.move(clip, toGroup: group.id) }
                    .disabled(clip.groupID == group.id)
            }
            if !model.groups.isEmpty { Divider() }
            Button("New Group…") { startNewGroup(adding: clip) }
        }
        if clip.groupID != nil {
            Button("Remove from Group") { model.move(clip, toGroup: nil) }
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete(clip) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: model.query.isEmpty ? "clipboard" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var emptyMessage: String {
        if !model.query.isEmpty { return "No clips match “\(model.query)”." }
        switch model.filter {
        case .all: return "Nothing copied yet.\nCopy something and it shows up here."
        case .pinned: return "No pinned clips.\nPin one with ⌘P."
        case .group: return "This group is empty.\nRight-click a clip › Move to Group."
        }
    }

    private var footer: some View {
        Text("↩ paste · ⇧↩ plain text · ⌥↩ copy · ⌘P pin · ⌘⌫ delete · ⇥ groups")
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    // MARK: - Group name prompt

    private enum GroupPrompt {
        case create(adding: ClipSummary?)
        case rename(ClipGroup)

        var title: String {
            switch self {
            case .create: return "New Group"
            case .rename: return "Rename Group"
            }
        }

        var confirmLabel: String {
            switch self {
            case .create: return "Create"
            case .rename: return "Rename"
            }
        }
    }

    private func startNewGroup(adding clip: ClipSummary?) {
        groupName = ""
        groupPrompt = .create(adding: clip)
    }

    private func startRename(_ group: ClipGroup) {
        groupName = group.name
        groupPrompt = .rename(group)
    }

    private func commitGroupPrompt() {
        switch groupPrompt {
        case .create(let clip): model.createGroup(named: groupName, adding: clip)
        case .rename(let group): model.renameGroup(group, to: groupName)
        case nil: break
        }
        groupPrompt = nil
        model.requestFocus()
    }
}

private struct FilterBar: View {
    @ObservedObject var model: PopupModel
    var onNewGroup: () -> Void
    var onRename: (ClipGroup) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", systemImage: "clock", filter: .all)
                chip("Pinned", systemImage: "pin", filter: .pinned)
                ForEach(model.groups) { group in
                    chip(group.name, systemImage: "folder", filter: .group(group.id))
                        .contextMenu {
                            Button("Rename…") { onRename(group) }
                            Button("Delete Group", role: .destructive) { model.deleteGroup(group) }
                        }
                }
                Button(action: onNewGroup) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New group")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func chip(_ title: String, systemImage: String, filter: ClipFilter) -> some View {
        let selected = model.filter == filter
        return Button {
            model.filter = filter
            model.selectFirst()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(selected ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.07)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct ClipRow: View {
    let clip: ClipSummary
    let position: Int
    let isSelected: Bool
    let groupName: String?
    let thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(position < 10 ? "\((position + 1) % 10)" : "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            leadingVisual
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title)
                    .font(.system(size: 13))
                    .lineLimit(clip.kind == .image ? 1 : 2)
                    .truncationMode(.tail)
                details
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.clear))
        .contentShape(Rectangle())
        .help(clip.title)
    }

    @ViewBuilder
    private var leadingVisual: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
        }
    }

    private var symbol: String {
        switch clip.kind {
        case .text: return "text.alignleft"
        case .richText: return "doc.richtext"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        case .other: return "shippingbox"
        }
    }

    private var details: some View {
        HStack(spacing: 4) {
            if clip.pinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.orange)
            }
            if let groupName {
                Label(groupName, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            if let icon = IconCache.appIcon(bundleID: clip.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 12, height: 12)
            }
            Text(detailText)
                .lineLimit(1)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private var detailText: String {
        var parts: [String] = []
        if let source = clip.sourceName { parts.append(source) }
        parts.append(Self.relativeFormatter.localizedString(for: clip.lastUsed, relativeTo: Date()))
        if clip.byteSize >= 100_000 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(clip.byteSize), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
