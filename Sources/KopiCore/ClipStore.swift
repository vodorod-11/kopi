import Foundation

/// The clipboard history database: clips, their data and groups.
public final class ClipStore {
    public enum InsertResult: Equatable {
        /// A new clip was stored.
        case inserted(Int64)
        /// The same content was already stored; that clip moved to the top instead.
        case updated(Int64)

        public var id: Int64 {
            switch self {
            case .inserted(let id), .updated(let id): return id
            }
        }
    }

    public let database: SQLiteDatabase

    /// Opens (and creates or migrates) the store. Use ":memory:" for a throw-away store.
    public init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try migrate()
    }

    private func migrate() throws {
        try database.execute("PRAGMA foreign_keys = ON")
        let version = try database.scalar("PRAGMA user_version") ?? 0
        if version < 1 {
            // auto_vacuum only takes effect before the first table exists.
            try database.execute("PRAGMA auto_vacuum = INCREMENTAL")
            try database.execute("PRAGMA journal_mode = WAL")
            try database.execute("""
                CREATE TABLE IF NOT EXISTS clip_groups (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    sort INTEGER NOT NULL DEFAULT 0,
                    created REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS clips (
                    id INTEGER PRIMARY KEY,
                    hash TEXT NOT NULL,
                    kind INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    search_text TEXT NOT NULL,
                    thumbnail BLOB,
                    source_bundle TEXT,
                    source_name TEXT,
                    byte_size INTEGER NOT NULL,
                    created REAL NOT NULL,
                    last_used REAL NOT NULL,
                    use_count INTEGER NOT NULL DEFAULT 0,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    group_id INTEGER REFERENCES clip_groups(id) ON DELETE SET NULL
                );
                CREATE INDEX IF NOT EXISTS clips_last_used ON clips(last_used);
                CREATE INDEX IF NOT EXISTS clips_hash ON clips(hash);
                CREATE INDEX IF NOT EXISTS clips_group ON clips(group_id);
                CREATE TABLE IF NOT EXISTS clip_data (
                    clip_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                    item INTEGER NOT NULL,
                    position INTEGER NOT NULL,
                    type TEXT NOT NULL,
                    data BLOB NOT NULL,
                    PRIMARY KEY (clip_id, item, position)
                );
                PRAGMA user_version = 1;
                """)
        }
    }

    // MARK: - Clips

    /// Stores a copy. A copy whose content is already stored bumps that clip to the top instead.
    @discardableResult
    public func insert(
        _ content: ClipContent,
        plainText: String? = nil,
        sourceBundleID: String? = nil,
        sourceName: String? = nil,
        now: Date = Date()
    ) throws -> InsertResult {
        let text = plainText ?? content.basicPlainText
        let hash = content.contentHash(plainText: text)

        if let existing = try database.scalar("SELECT id FROM clips WHERE hash = ? LIMIT 1", [hash]) {
            try database.run(
                """
                UPDATE clips SET last_used = ?, source_bundle = COALESCE(?, source_bundle),
                    source_name = COALESCE(?, source_name)
                WHERE id = ?
                """,
                [now, sourceBundleID, sourceName, existing])
            return .updated(existing)
        }

        let kind = content.kind
        let title = Self.title(for: content, kind: kind, text: text)
        let searchText = ClipText.searchKey(title + "\n" + (text ?? ""))
        var thumbnail: Data?
        if kind == .image, let image = content.firstData(forAnyOf: PasteboardType.imageTypes) {
            thumbnail = Thumbnailer.thumbnail(image.data)
        }

        return try database.transaction {
            try database.run(
                """
                INSERT INTO clips (hash, kind, title, search_text, thumbnail, source_bundle, source_name,
                                   byte_size, created, last_used)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [hash, kind.rawValue, title, searchText, thumbnail, sourceBundleID, sourceName,
                 content.byteSize, now, now])
            let id = database.lastInsertRowID
            let statement = try database.prepare(
                "INSERT INTO clip_data (clip_id, item, position, type, data) VALUES (?, ?, ?, ?, ?)")
            for (itemIndex, item) in content.items.enumerated() {
                for (position, representation) in item.representations.enumerated() {
                    try statement.bind([id, itemIndex, position, representation.type, representation.data])
                    while try statement.step() {}
                }
            }
            return .inserted(id)
        }
    }

    static func title(for content: ClipContent, kind: ClipKind, text: String?) -> String {
        switch kind {
        case .files:
            let names = content.fileURLs.map { $0.lastPathComponent }
            if names.count == 1 { return names[0] }
            return "\(names.count) files: " + ClipText.title(names.joined(separator: ", "), limit: 250)
        case .image:
            if let image = content.firstData(forAnyOf: PasteboardType.imageTypes),
               let size = Thumbnailer.pixelSize(image.data) {
                return "Image \(size.width) × \(size.height)"
            }
            return content.allTypes.contains(PasteboardType.pdf) ? "PDF" : "Image"
        case .text, .richText:
            let title = ClipText.title(text ?? "")
            return title.isEmpty ? "(blank)" : title
        case .other:
            return content.items.first?.types.first ?? "Unknown data"
        }
    }

    private static let summaryColumns = """
        id, kind, title, source_bundle, source_name, byte_size, created, last_used, use_count,
        pinned, group_id, thumbnail IS NOT NULL
        """

    private static func summary(_ row: SQLiteStatement) -> ClipSummary {
        ClipSummary(
            id: row.int64(0),
            kind: ClipKind(rawValue: row.int(1)) ?? .other,
            title: row.string(2) ?? "",
            sourceBundleID: row.string(3),
            sourceName: row.string(4),
            byteSize: row.int(5),
            created: row.date(6),
            lastUsed: row.date(7),
            useCount: row.int(8),
            pinned: row.bool(9),
            groupID: row.isNull(10) ? nil : row.int64(10),
            hasThumbnail: row.bool(11))
    }

    /// Clips for the history list, newest first. In `.all`, pinned clips come first.
    /// Every word of `query` must appear in the clip (case-insensitive).
    public func clips(filter: ClipFilter = .all, query: String = "", limit: Int = 2_000) throws -> [ClipSummary] {
        var conditions: [String] = []
        var parameters: [Any?] = []
        switch filter {
        case .all:
            break
        case .pinned:
            conditions.append("pinned = 1")
        case .group(let id):
            conditions.append("group_id = ?")
            parameters.append(id)
        }
        for word in ClipText.searchKey(query).split(whereSeparator: { $0.isWhitespace }) {
            conditions.append("instr(search_text, ?) > 0")
            parameters.append(String(word))
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let order = filter == .all ? "pinned DESC, last_used DESC, id DESC" : "last_used DESC, id DESC"
        parameters.append(limit)
        return try database.query(
            "SELECT \(Self.summaryColumns) FROM clips \(whereClause) ORDER BY \(order) LIMIT ?",
            parameters, Self.summary)
    }

    public func clip(id: Int64) throws -> ClipSummary? {
        try database.query("SELECT \(Self.summaryColumns) FROM clips WHERE id = ?", [id], Self.summary).first
    }

    public func thumbnail(id: Int64) throws -> Data? {
        let values: [Data?] = try database.query("SELECT thumbnail FROM clips WHERE id = ?", [id]) { $0.data(0) }
        return values.first ?? nil
    }

    /// The stored pasteboard data of a clip, ready to be written back.
    public func content(id: Int64) throws -> ClipContent? {
        let rows = try database.query(
            "SELECT item, type, data FROM clip_data WHERE clip_id = ? ORDER BY item, position", [id]
        ) { row in (row.int(0), row.string(1) ?? "", row.data(2) ?? Data()) }
        guard !rows.isEmpty else { return nil }
        var items: [ClipItem] = []
        var currentItem = -1
        for (item, type, data) in rows {
            if item != currentItem {
                items.append(ClipItem([]))
                currentItem = item
            }
            items[items.count - 1].representations.append(Representation(type: type, data: data))
        }
        return ClipContent(items: items)
    }

    /// Records a paste. With `moveToTop` the clip also becomes the newest one.
    public func markUsed(_ id: Int64, moveToTop: Bool, now: Date = Date()) throws {
        if moveToTop {
            try database.run("UPDATE clips SET use_count = use_count + 1, last_used = ? WHERE id = ?", [now, id])
        } else {
            try database.run("UPDATE clips SET use_count = use_count + 1 WHERE id = ?", [id])
        }
    }

    public func setPinned(_ id: Int64, _ pinned: Bool) throws {
        try database.run("UPDATE clips SET pinned = ? WHERE id = ?", [pinned, id])
    }

    public func setGroup(_ id: Int64, _ groupID: Int64?) throws {
        try database.run("UPDATE clips SET group_id = ? WHERE id = ?", [groupID, id])
    }

    public func delete(_ id: Int64) throws {
        try database.run("DELETE FROM clips WHERE id = ?", [id])
    }

    /// Deletes every clip that is neither pinned nor in a group.
    @discardableResult
    public func clearHistory() throws -> Int {
        let removed = try database.run("DELETE FROM clips WHERE pinned = 0 AND group_id IS NULL")
        try? database.execute("PRAGMA incremental_vacuum")
        return removed
    }

    /// Applies the history limits. Pinned and grouped clips are never removed.
    /// `maxCount` or `maxAge` of 0 means no limit.
    @discardableResult
    public func trim(maxCount: Int, maxAge: TimeInterval, now: Date = Date()) throws -> Int {
        var removed = 0
        if maxAge > 0 {
            removed += try database.run(
                "DELETE FROM clips WHERE pinned = 0 AND group_id IS NULL AND last_used < ?",
                [now.addingTimeInterval(-maxAge)])
        }
        if maxCount > 0 {
            removed += try database.run(
                """
                DELETE FROM clips WHERE id IN (
                    SELECT id FROM clips WHERE pinned = 0 AND group_id IS NULL
                    ORDER BY last_used DESC, id DESC LIMIT -1 OFFSET ?)
                """,
                [maxCount])
        }
        if removed > 0 {
            try? database.execute("PRAGMA incremental_vacuum")
        }
        return removed
    }

    public func statistics() throws -> (clips: Int, bytes: Int) {
        let rows = try database.query("SELECT COUNT(*), COALESCE(SUM(byte_size), 0) FROM clips") { ($0.int(0), $0.int(1)) }
        return rows.first ?? (0, 0)
    }

    // MARK: - Groups

    public func groups() throws -> [ClipGroup] {
        try database.query(
            """
            SELECT g.id, g.name, (SELECT COUNT(*) FROM clips c WHERE c.group_id = g.id)
            FROM clip_groups g ORDER BY g.sort, g.name COLLATE NOCASE
            """
        ) { ClipGroup(id: $0.int64(0), name: $0.string(1) ?? "", clipCount: $0.int(2)) }
    }

    @discardableResult
    public func createGroup(named name: String, now: Date = Date()) throws -> Int64 {
        let sort = (try database.scalar("SELECT MAX(sort) FROM clip_groups") ?? 0) + 1
        try database.run("INSERT INTO clip_groups (name, sort, created) VALUES (?, ?, ?)", [name, sort, now])
        return database.lastInsertRowID
    }

    public func renameGroup(_ id: Int64, to name: String) throws {
        try database.run("UPDATE clip_groups SET name = ? WHERE id = ?", [name, id])
    }

    /// Deletes the group. Its clips stay in the history, outside any group.
    public func deleteGroup(_ id: Int64) throws {
        try database.run("DELETE FROM clip_groups WHERE id = ?", [id])
    }
}
