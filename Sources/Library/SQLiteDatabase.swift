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
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        // WAL plus NORMAL durability avoids a full fsync for every completed
        // word while retaining crash-safe committed transactions.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA temp_store = MEMORY")
        try execute("PRAGMA cache_size = -8192")
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
                language TEXT NOT NULL DEFAULT 'other',
                PRIMARY KEY (word, source)
            )
            """
        )
        try addColumnIfMissing(table: "word_stats", name: "language", definition: "TEXT NOT NULL DEFAULT 'other'")
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
            CREATE TABLE IF NOT EXISTS daily_word_stats (
                day TEXT NOT NULL,
                word TEXT NOT NULL,
                source TEXT NOT NULL,
                frequency INTEGER NOT NULL,
                avg_ms REAL NOT NULL,
                last_used_at REAL NOT NULL,
                language TEXT NOT NULL DEFAULT 'other',
                PRIMARY KEY (day, word, source)
            )
            """
        )
        try addColumnIfMissing(table: "daily_word_stats", name: "language", definition: "TEXT NOT NULL DEFAULT 'other'")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS daily_chord_stats (
                day TEXT NOT NULL,
                output TEXT NOT NULL,
                matched_chord_id TEXT NOT NULL,
                source TEXT NOT NULL,
                frequency INTEGER NOT NULL,
                avg_ms REAL NOT NULL,
                confidence TEXT NOT NULL,
                ambiguity_count INTEGER NOT NULL,
                last_used_at REAL NOT NULL,
                PRIMARY KEY (day, output, matched_chord_id, source, confidence)
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS daily_word_stats_word ON daily_word_stats(word)")
        try execute("CREATE INDEX IF NOT EXISTS daily_word_stats_language ON daily_word_stats(language)")
        try execute("CREATE INDEX IF NOT EXISTS daily_word_stats_last_used ON daily_word_stats(last_used_at)")
        try execute("CREATE INDEX IF NOT EXISTS daily_chord_stats_output ON daily_chord_stats(output)")
        try execute("CREATE INDEX IF NOT EXISTS daily_chord_stats_chord ON daily_chord_stats(matched_chord_id)")
        try execute("CREATE INDEX IF NOT EXISTS daily_chord_stats_last_used ON daily_chord_stats(last_used_at)")
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
        // Word-level suggestion bans were never exposed in the UI and are no longer
        // part of suggestion generation. Keep this table only for banned chord inputs.
        try execute("DELETE FROM bans WHERE kind = 'word'")
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
        // How often a typed word was finished by an autocomplete key (Tab,
        // Right Arrow). The completed text never reaches the recorder, so this
        // is the evidence that `zelv` was really `zelvora`.
        try execute(
            """
            CREATE TABLE IF NOT EXISTS daily_completion_stats (
                day TEXT NOT NULL,
                word TEXT NOT NULL,
                frequency INTEGER NOT NULL,
                PRIMARY KEY (day, word)
            )
            """
        )
        // Words that should be counted as another word: autocomplete
        // fragments and personal misspellings folded into the real word.
        try execute(
            """
            CREATE TABLE IF NOT EXISTS word_aliases (
                word TEXT PRIMARY KEY,
                target TEXT NOT NULL,
                source TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """
        )
        // Two- and three-word phrases, as counts only, for phrase chords.
        try execute(
            """
            CREATE TABLE IF NOT EXISTS daily_phrase_stats (
                day TEXT NOT NULL,
                phrase TEXT NOT NULL,
                word_count INTEGER NOT NULL,
                frequency INTEGER NOT NULL,
                hand_frequency INTEGER NOT NULL,
                PRIMARY KEY (day, phrase)
            )
            """
        )
        // Letter-by-letter speed drills and the letter pairs that slow you down.
        try execute(
            """
            CREATE TABLE IF NOT EXISTS speed_drills (
                id TEXT PRIMARY KEY,
                finished_at REAL NOT NULL,
                wpm REAL NOT NULL,
                accuracy REAL NOT NULL,
                characters INTEGER NOT NULL,
                slow_bigrams_json TEXT NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS drill_bigrams (
                bigram TEXT PRIMARY KEY,
                total_ms REAL NOT NULL,
                count INTEGER NOT NULL
            )
            """
        )
        // Words-per-minute samples: characters and time from the end of the
        // previous word, per input method (keyboard, M4G letters, M4G chords).
        try execute(
            """
            CREATE TABLE IF NOT EXISTS daily_speed_stats (
                day TEXT NOT NULL,
                method TEXT NOT NULL,
                words INTEGER NOT NULL,
                characters INTEGER NOT NULL,
                cycle_ms REAL NOT NULL,
                PRIMARY KEY (day, method)
            )
            """
        )
        // Chords that fired wrong: deleted right away, or letters that came
        // out at chord speed but match no chord and no word.
        try execute(
            """
            CREATE TABLE IF NOT EXISTS daily_misfire_stats (
                day TEXT NOT NULL,
                word TEXT NOT NULL,
                kind TEXT NOT NULL,
                frequency INTEGER NOT NULL,
                PRIMARY KEY (day, word, kind)
            )
            """
        )
        // Keystroke and backspace counts per day, for the correction rate.
        try execute(
            """
            CREATE TABLE IF NOT EXISTS daily_key_stats (
                day TEXT PRIMARY KEY,
                keystrokes INTEGER NOT NULL,
                backspaces INTEGER NOT NULL
            )
            """
        )
        try migrateMultilingualWordsIfNeeded()
    }

    private struct WordAggregateKey: Hashable {
        let word: String
        let source: String
    }

    private struct DailyWordAggregateKey: Hashable {
        let day: String
        let word: String
        let source: String
    }

    private struct WordAggregate {
        var frequency: Int
        var weightedMilliseconds: Double
        var lastUsedAt: Double
        let language: WordLanguage

        var averageMilliseconds: Double {
            weightedMilliseconds / Double(max(frequency, 1))
        }
    }

    /// Rewrites legacy word keys exactly once so Arabic tashkeel/tatweel and
    /// Unicode case variants do not fragment frequency statistics. Compounds
    /// that Natural Language recognizes as multiple words are split while
    /// retaining their original aggregate frequency.
    private func migrateMultilingualWordsIfNeeded() throws {
        let migrationKey = "usage.multilingual_words.v1"
        let completed = try query(
            "SELECT value FROM settings WHERE key = ?",
            bindings: [.text(migrationKey)]
        ).first?.string("value") == "complete"
        guard !completed else { return }

        let allTimeRows = try query(
            "SELECT word, source, frequency, avg_ms, last_used_at FROM word_stats"
        )
        let dailyRows = try query(
            "SELECT day, word, source, frequency, avg_ms, last_used_at FROM daily_word_stats"
        )

        var allTime: [WordAggregateKey: WordAggregate] = [:]
        for row in allTimeRows {
            guard let rawWord = row.string("word"),
                  let source = row.string("source"),
                  let frequencyValue = row.integer("frequency"),
                  let average = row.double("avg_ms"),
                  let lastUsedAt = row.double("last_used_at") else { continue }
            let frequency = Int(frequencyValue)
            for processed in MultilingualWordProcessor.words(in: rawWord) {
                let key = WordAggregateKey(word: processed.text, source: source)
                var value = allTime[key] ?? WordAggregate(
                    frequency: 0,
                    weightedMilliseconds: 0,
                    lastUsedAt: lastUsedAt,
                    language: processed.language
                )
                value.frequency += frequency
                value.weightedMilliseconds += average * Double(frequency)
                value.lastUsedAt = max(value.lastUsedAt, lastUsedAt)
                allTime[key] = value
            }
        }

        var daily: [DailyWordAggregateKey: WordAggregate] = [:]
        for row in dailyRows {
            guard let day = row.string("day"),
                  let rawWord = row.string("word"),
                  let source = row.string("source"),
                  let frequencyValue = row.integer("frequency"),
                  let average = row.double("avg_ms"),
                  let lastUsedAt = row.double("last_used_at") else { continue }
            let frequency = Int(frequencyValue)
            for processed in MultilingualWordProcessor.words(in: rawWord) {
                let key = DailyWordAggregateKey(day: day, word: processed.text, source: source)
                var value = daily[key] ?? WordAggregate(
                    frequency: 0,
                    weightedMilliseconds: 0,
                    lastUsedAt: lastUsedAt,
                    language: processed.language
                )
                value.frequency += frequency
                value.weightedMilliseconds += average * Double(frequency)
                value.lastUsedAt = max(value.lastUsedAt, lastUsedAt)
                daily[key] = value
            }
        }

        try transaction {
            try execute("DELETE FROM word_stats")
            for (key, value) in allTime {
                try execute(
                    "INSERT INTO word_stats (word, frequency, avg_ms, last_used_at, source, language) VALUES (?, ?, ?, ?, ?, ?)",
                    bindings: [
                        .text(key.word),
                        .integer(Int64(value.frequency)),
                        .double(value.averageMilliseconds),
                        .double(value.lastUsedAt),
                        .text(key.source),
                        .text(value.language.rawValue)
                    ]
                )
            }

            try execute("DELETE FROM daily_word_stats")
            for (key, value) in daily {
                try execute(
                    "INSERT INTO daily_word_stats (day, word, source, frequency, avg_ms, last_used_at, language) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    bindings: [
                        .text(key.day),
                        .text(key.word),
                        .text(key.source),
                        .integer(Int64(value.frequency)),
                        .double(value.averageMilliseconds),
                        .double(value.lastUsedAt),
                        .text(value.language.rawValue)
                    ]
                )
            }
            try execute(
                "INSERT OR REPLACE INTO settings (key, value) VALUES (?, 'complete')",
                bindings: [.text(migrationKey)]
            )
        }
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
