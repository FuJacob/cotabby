import Foundation
import SQLite3

/// File overview:
/// A minimal read-only view of another app's SQLite database (WhatsApp's ChatStorage, Mail's
/// Envelope Index), for the memory readers.
///
/// Why its own type: these stores belong to other apps that are writing to them right now. The
/// database is opened in place with `SQLITE_OPEN_READONLY` (never copied: a copy of someone's chat
/// history in a temp folder would be one more plaintext file to leak), so SQLite's WAL handling
/// gives a consistent snapshot while the owning app keeps writing, and Cotabby can never modify it.
/// The SQLite C API is wrapped here once, with its pointer and lifetime rules, so the readers deal
/// only in rows of Swift values.
///
/// Not thread-safe: each read pass opens its own instance on its own background task.
nonisolated final class ReadOnlySQLiteDatabase {
    enum DatabaseError: LocalizedError {
        /// macOS refused the open (Full Disk Access or App Data protection not granted).
        case notPermitted(String)
        case missing(String)
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted(let path): return "Cotabby is not allowed to read \(path). Grant Full Disk Access."
            case .missing(let path): return "\(path) does not exist."
            case .sqlite(let message): return message
            }
        }
    }

    /// One column value. SQLite is dynamically typed per value, so a row is read as these.
    enum Value: Equatable {
        case integer(Int64)
        case real(Double)
        case text(String)
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
            switch self {
            case .text(let value): return value
            case .integer(let value): return String(value)
            case .real(let value): return String(value)
            case .null: return nil
            }
        }
    }

    private var handle: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        guard FileManager.default.fileExists(atPath: path) else { throw DatabaseError.missing(path) }
        // Probe with a plain open(2) first: TCC denials surface as EPERM there, which SQLite would
        // otherwise report as a generic "unable to open database file".
        let probe = open(path, O_RDONLY)
        if probe < 0 {
            let code = errno
            throw code == EPERM || code == EACCES ? DatabaseError.notPermitted(path) : DatabaseError.sqlite(String(cString: strerror(code)))
        }
        close(probe)
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw DatabaseError.sqlite(message)
        }
        // The owner may hold a write lock briefly; wait rather than fail.
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Whether `table` has every one of `columns`: the schema probe that keeps a reader from
    /// misreading a store whose undocumented layout changed in an app update.
    func hasColumns(_ columns: [String], in table: String) throws -> Bool {
        let present = Set(try rows("PRAGMA table_info(\(table))").compactMap { $0["name"]?.string })
        return Set(columns).isSubset(of: present)
    }

    /// Runs `sql` with positional parameters and returns every row as column name -> value.
    func rows(_ sql: String, _ parameters: [Value] = []) throws -> [[String: Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, parameter) in parameters.enumerated() {
            Self.bind(parameter, at: Int32(offset + 1), in: statement)
        }
        var result: [[String: Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw DatabaseError.sqlite(String(cString: sqlite3_errmsg(handle))) }
            var row: [String: Value] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                row[String(cString: sqlite3_column_name(statement, column))] = Self.value(at: column, in: statement)
            }
            result.append(row)
        }
        return result
    }

    private static func bind(_ parameter: Value, at index: Int32, in statement: OpaquePointer?) {
        switch parameter {
        case .integer(let value): sqlite3_bind_int64(statement, index, value)
        case .real(let value): sqlite3_bind_double(statement, index, value)
        // SQLITE_TRANSIENT (-1): SQLite copies the string, since Swift's buffer is temporary.
        case .text(let value): sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        case .null: sqlite3_bind_null(statement, index)
        }
    }

    private static func value(at column: Int32, in statement: OpaquePointer?) -> Value {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, column)))
        default: return .null
        }
    }
}
