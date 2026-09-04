import Foundation
import SQLite3

/// A thin wrapper over the system SQLite, which every Apple platform already
/// ships. No package, nothing to download, nothing resident that we did not
/// write -- which matters on a machine that records meetings while Docker and
/// a couple of editors are already competing for memory.
///
/// Deliberately small: the app makes about twenty distinct queries, all of them
/// simple, so an ORM would be more code to understand than the SQL it hides.
final class SQLite {

    /// SQLITE_TRANSIENT. SQLite must copy bound text rather than hold a pointer
    /// into a Swift String whose buffer is gone by the time the statement runs.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Error: LocalizedError {
        let message: String
        let sql: String?
        var errorDescription: String? {
            sql.map { "\(message) — while running: \($0)" } ?? message
        }
    }

    private var handle: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
            sqlite3_close_v2(handle)
            throw Error(message: message, sql: nil)
        }
        self.handle = handle

        // Write-ahead logging so a read never blocks behind the write that
        // saves a transcript, and a foreign key actually means something --
        // SQLite ignores them unless asked, which would let a meeting be
        // deleted while its segments stayed behind forever.
        try execute("pragma journal_mode = wal")
        try execute("pragma foreign_keys = on")
        try execute("pragma busy_timeout = 5000")
        try execute("pragma synchronous = normal")
    }

    deinit { sqlite3_close_v2(handle) }

    // MARK: - Values

    enum Value {
        case null
        case int(Int)
        case double(Double)
        case text(String)

        init(_ v: String?) { self = v.map { .text($0) } ?? .null }
        init(_ v: Int?) { self = v.map { .int($0) } ?? .null }
        /// Lowercased. `UUID.uuidString` is uppercase, Postgres writes
        /// lowercase, and SQLite compares text case-sensitively -- so a
        /// transcript imported from Postgres was invisible to every
        /// `where meeting_id = ?` the app ran. The columns are also declared
        /// `collate nocase`, so this is belt and braces; it costs nothing and
        /// keeps the file consistent with the tools that will read it.
        init(_ v: UUID?) { self = v.map { .text($0.uuidString.lowercased()) } ?? .null }
        /// Dates are stored as ISO-8601 text: comparable and orderable as
        /// strings, and readable when someone opens the file in a SQLite
        /// browser to see what went wrong.
        init(_ v: Date?) { self = v.map { .text(SQLite.iso.string(from: $0)) } ?? .null }
    }

    /// `nonisolated(unsafe)` because Swift 6 cannot see that this is safe, and
    /// it is: the formatter is configured once here and only ever read
    /// afterwards, and Foundation's date formatters have been documented as
    /// thread-safe for formatting and parsing since iOS 7. The alternative --
    /// building a formatter per call -- would run 1500 times while saving one
    /// long transcript.
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One row, addressable by column name so a query gaining a column does not
    /// silently shift every index after it.
    struct Row {
        private let values: [String: Value]
        init(_ values: [String: Value]) { self.values = values }

        func int(_ column: String) -> Int? {
            if case .int(let v) = values[column] ?? .null { return v }
            return nil
        }
        func string(_ column: String) -> String? {
            if case .text(let v) = values[column] ?? .null { return v }
            return nil
        }
        func uuid(_ column: String) -> UUID? { string(column).flatMap(UUID.init(uuidString:)) }
        func date(_ column: String) -> Date? {
            guard let s = string(column) else { return nil }
            return SQLite.iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
    }

    // MARK: - Running

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw Error(message: message, sql: sql)
        }
    }

    @discardableResult
    func run(_ sql: String, _ bindings: [Value] = []) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Error(message: String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        defer { sqlite3_finalize(statement) }

        for (i, value) in bindings.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let v): sqlite3_bind_int64(statement, index, Int64(v))
            case .double(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, Self.transient)
            }
        }

        var rows: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var values: [String: Value] = [:]
                for c in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, c))
                    switch sqlite3_column_type(statement, c) {
                    case SQLITE_INTEGER: values[name] = .int(Int(sqlite3_column_int64(statement, c)))
                    case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(statement, c))
                    case SQLITE_TEXT:
                        values[name] = .text(String(cString: sqlite3_column_text(statement, c)))
                    default: values[name] = .null
                    }
                }
                rows.append(Row(values))
            case SQLITE_DONE:
                return rows
            default:
                throw Error(message: String(cString: sqlite3_errmsg(handle)), sql: sql)
            }
        }
    }

    /// All-or-nothing. Saving a transcript writes speakers and then a thousand
    /// segments; half of that on disk is worse than none, because the meeting
    /// would look finished and read as though it stopped early.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("begin immediate")
        do {
            let result = try body()
            try execute("commit")
            return result
        } catch {
            try? execute("rollback")
            throw error
        }
    }
}
