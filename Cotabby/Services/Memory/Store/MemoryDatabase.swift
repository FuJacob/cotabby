import Foundation
import SQLite3

/// File overview:
/// A small read-write SQLite connection for conversation memory's own store.
///
/// Why a separate type from `ReadOnlySQLiteDatabase`: that one opens other apps' stores read-only
/// and probes for Full Disk Access; this one owns Cotabby's encrypted store, so it writes, binds
/// blobs (sealed values), runs transactions, and sets the durability and privacy pragmas once:
/// WAL so readers never block on a writer, and `secure_delete` so deleted or overwritten rows are
/// zeroed on disk instead of lingering in free pages (a purge or "Delete All" must remove bytes).
///
/// Not thread-safe by itself: `MemoryStore` serializes every call with its lock.
nonisolated final class MemoryDatabase {
    enum Value: Equatable {
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
        case null

        var int: Int64? {
            switch self {
            case .integer(let value): return value
            case .real(let value): return Int64(value)
            default: return nil
            }
        }

        var double: Double? {
            switch self {
            case .integer(let value): return Double(value)
            case .real(let value): return value
            default: return nil
            }
        }

        var string: String? {
            if case .text(let value) = self { return value }
            return nil
        }

        var data: Data? {
            if case .blob(let value) = self { return value }
            return nil
        }
    }

    struct DatabaseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var handle: OpaquePointer?
    let path: String

    /// SQLITE_TRANSIENT: SQLite copies bound text and blobs, since Swift's buffers are temporary.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw DatabaseError(message: message)
        }
        sqlite3_busy_timeout(handle, 5000)
        chmod(path, 0o600)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA secure_delete = ON")
        try execute("PRAGMA foreign_keys = OFF")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw DatabaseError(message: message)
        }
    }

    /// Runs a statement that returns no rows; returns the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ parameters: [Value] = []) throws -> Int {
        try withStatement(sql, parameters) { statement in
            let step = sqlite3_step(statement)
            guard step == SQLITE_DONE || step == SQLITE_ROW else { throw lastError() }
        }
        return Int(sqlite3_changes(handle))
    }

    /// Runs `sql` and returns every row as column name -> value.
    func rows(_ sql: String, _ parameters: [Value] = []) throws -> [[String: Value]] {
        try withStatement(sql, parameters) { statement in
            var result: [[String: Value]] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw lastError() }
                var row: [String: Value] = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    row[String(cString: sqlite3_column_name(statement, column))] = value(statement, column)
                }
                result.append(row)
            }
            return result
        }
    }

    /// Runs `body` in one transaction, rolled back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
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

    // MARK: - Statements

    private func withStatement<T>(_ sql: String, _ parameters: [Value], _ body: (OpaquePointer?) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .blob(let value):
                _ = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return try body(statement)
    }

    private func value(_ statement: OpaquePointer?, _ column: Int32) -> Value {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }

    private func lastError() -> DatabaseError {
        DatabaseError(message: String(cString: sqlite3_errmsg(handle)))
    }
}
