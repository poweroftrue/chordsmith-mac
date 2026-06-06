import Foundation
import SQLite3

enum SQLiteValue: Sendable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)

    init(bool: Bool) {
        self = .integer(bool ? 1 : 0)
    }

    static func bool(bool: Bool) -> SQLiteValue {
        .integer(bool ? 1 : 0)
    }
}

struct SQLiteRow: Sendable {
    let values: [String: SQLiteValue]

    func string(_ name: String) -> String? {
        guard case .text(let value)? = values[name] else { return nil }
        return value
    }

    func integer(_ name: String) -> Int64? {
        guard case .integer(let value)? = values[name] else { return nil }
        return value
    }

    func double(_ name: String) -> Double? {
        switch values[name] {
        case .double(let value)?:
            return value
        case .integer(let value)?:
            return Double(value)
        default:
            return nil
        }
    }
}

final class SQLiteDatabase {
    private let handle: OpaquePointer

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var db: OpaquePointer?
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open failure"
            if let db {
                sqlite3_close(db)
            }
            throw LibraryError.sqliteError(message)
        }

        guard let db else {
            throw LibraryError.sqliteError("SQLite handle was not created.")
        }

        handle = db
        try execute("PRAGMA foreign_keys = ON")
        try migrate()
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw lastError()
        }
    }

    func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }

        var rows: [SQLiteRow] = []

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw lastError()
            }

            let columnCount = sqlite3_column_count(statement)
            var values: [String: SQLiteValue] = [:]
            values.reserveCapacity(Int(columnCount))

            for index in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, index))
                let type = sqlite3_column_type(statement, index)
                switch type {
                case SQLITE_INTEGER:
                    values[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    values[name] = .double(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    values[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                default:
                    values[name] = .null
                }
            }

            rows.append(SQLiteRow(values: values))
        }

        return rows
    }

    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, bindings: [SQLiteValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }

        for (index, binding) in bindings.enumerated() {
            let sqliteIndex = Int32(index + 1)
            switch binding {
            case .null:
                sqlite3_bind_null(statement, sqliteIndex)
            case .integer(let value):
                sqlite3_bind_int64(statement, sqliteIndex, value)
            case .double(let value):
                sqlite3_bind_double(statement, sqliteIndex, value)
            case .text(let value):
                sqlite3_bind_text(statement, sqliteIndex, value, -1, SQLITE_TRANSIENT)
            }
        }

        return statement
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS chords (
                id TEXT PRIMARY KEY,
                input_keys_json TEXT NOT NULL,
                normalized_input TEXT NOT NULL,
                output TEXT NOT NULL,
                profile TEXT NOT NULL,
                deployment_target TEXT NOT NULL,
                source TEXT NOT NULL,
                enabled INTEGER NOT NULL,
                input_identity TEXT,
                raw_input TEXT,
                raw_output TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
        try addColumnIfMissing(table: "chords", name: "input_identity", definition: "TEXT")
        try addColumnIfMissing(table: "chords", name: "raw_input_actions_json", definition: "TEXT")
        try addColumnIfMissing(table: "chords", name: "raw_phrase_actions_json", definition: "TEXT")
        try addColumnIfMissing(table: "chords", name: "display_input_json", definition: "TEXT")
        try addColumnIfMissing(table: "chords", name: "phrase_tokens_json", definition: "TEXT")
        try addColumnIfMissing(table: "chords", name: "action_flags_json", definition: "TEXT")
        try addColumnIfMissing(table: "chords", name: "plain_output", definition: "TEXT")
        try execute("UPDATE chords SET input_identity = COALESCE(raw_input, normalized_input) WHERE input_identity IS NULL")
        try execute("DROP INDEX IF EXISTS chords_unique_input")
        try execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS chords_unique_identity
            ON chords(profile, deployment_target, input_identity)
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS word_stats (
                word TEXT NOT NULL,
                frequency INTEGER NOT NULL,
                avg_ms REAL NOT NULL,
                last_used_at REAL NOT NULL,
                source TEXT NOT NULL,
                PRIMARY KEY (word, source)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS chord_feedback (
                chord_id TEXT PRIMARY KEY,
                starred INTEGER NOT NULL,
                source TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                FOREIGN KEY(chord_id) REFERENCES chords(id) ON DELETE CASCADE
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS chord_stats (
                output TEXT NOT NULL,
                frequency INTEGER NOT NULL,
                last_used_at REAL NOT NULL,
                source TEXT NOT NULL,
                PRIMARY KEY (output, source)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS suggestions (
                word TEXT NOT NULL,
                profile TEXT NOT NULL,
                candidates_json TEXT NOT NULL,
                priority_score REAL NOT NULL,
                accepted_chord_id TEXT,
                banned_at REAL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (word, profile)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS bans (
                kind TEXT NOT NULL,
                value TEXT NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY (kind, value)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sources (
                id TEXT PRIMARY KEY,
                port_path TEXT NOT NULL,
                device_name TEXT NOT NULL,
                firmware TEXT NOT NULL,
                chord_count INTEGER NOT NULL,
                is_primary INTEGER NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """
        )
    }

    private func addColumnIfMissing(table: String, name: String, definition: String) throws {
        let rows = try query("PRAGMA table_info(\(table))")
        let existing = Set(rows.compactMap { $0.string("name") })
        guard !existing.contains(name) else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(name) \(definition)")
    }

    private func lastError() -> LibraryError {
        LibraryError.sqliteError(String(cString: sqlite3_errmsg(handle)))
    }
}

// SQLite wants a stable C symbol for transient text.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
