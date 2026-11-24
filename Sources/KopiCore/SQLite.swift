import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "SQLite: \(message)" }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal wrapper over the system SQLite library. One connection, used from one thread.
public final class SQLiteDatabase {
    fileprivate let handle: OpaquePointer

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(db)
            throw SQLiteError(message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Rows changed by the last INSERT, UPDATE or DELETE (cascaded deletes are not counted).
    public var changes: Int { Int(sqlite3_changes(handle)) }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError
            sqlite3_free(error)
            throw SQLiteError(message: message)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(database: self, sql: sql)
    }

    /// Runs a statement to completion and returns the number of changed rows.
    @discardableResult
    public func run(_ sql: String, _ parameters: [Any?] = []) throws -> Int {
        let statement = try prepare(sql)
        try statement.bind(parameters)
        while try statement.step() {}
        return changes
    }

    public func query<T>(_ sql: String, _ parameters: [Any?] = [], _ map: (SQLiteStatement) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        try statement.bind(parameters)
        var rows: [T] = []
        while try statement.step() {
            rows.append(try map(statement))
        }
        return rows
    }

    /// First column of the first row as an integer, or nil when there is no row or it is NULL.
    public func scalar(_ sql: String, _ parameters: [Any?] = []) throws -> Int64? {
        let values: [Int64?] = try query(sql, parameters) { $0.isNull(0) ? nil : $0.int64(0) }
        return values.first ?? nil
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

public final class SQLiteStatement {
    private let statement: OpaquePointer
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase, sql: String) throws {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database.handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw SQLiteError(message: "\(database.lastError) in: \(sql)")
        }
        statement = prepared
        self.database = database
    }

    deinit {
        sqlite3_finalize(statement)
    }

    /// Resets the statement and binds the parameters (Bool, Int, Int64, Double, Date, String, Data or nil).
    public func bind(_ parameters: [Any?]) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .none:
                rc = sqlite3_bind_null(statement, index)
            case let v as Bool:
                rc = sqlite3_bind_int64(statement, index, v ? 1 : 0)
            case let v as Int:
                rc = sqlite3_bind_int64(statement, index, Int64(v))
            case let v as Int64:
                rc = sqlite3_bind_int64(statement, index, v)
            case let v as Double:
                rc = sqlite3_bind_double(statement, index, v)
            case let v as Date:
                rc = sqlite3_bind_double(statement, index, v.timeIntervalSince1970)
            case let v as String:
                rc = sqlite3_bind_text(statement, index, v, -1, transient)
            case let v as Data:
                if v.isEmpty {
                    rc = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    rc = v.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
                    }
                }
            default:
                throw SQLiteError(message: "unsupported parameter type \(type(of: value))")
            }
            guard rc == SQLITE_OK else { throw SQLiteError(message: database.lastError) }
        }
    }

    /// Advances to the next row. Returns false when the statement is done.
    public func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(message: database.lastError)
        }
    }

    public func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    public func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    public func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    public func bool(_ column: Int32) -> Bool {
        sqlite3_column_int64(statement, column) != 0
    }

    public func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    public func date(_ column: Int32) -> Date {
        Date(timeIntervalSince1970: double(column))
    }

    public func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    public func data(_ column: Int32) -> Data? {
        if isNull(column) { return nil }
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
