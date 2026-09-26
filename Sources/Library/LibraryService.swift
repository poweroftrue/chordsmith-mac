import Foundation

public actor LibraryService {
    private let database: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let suggestionEngine: SuggestionEngine
    private static let chordColumns = """
        id, input_keys_json, normalized_input, output, profile, deployment_target, source, enabled,
        raw_input, raw_output, raw_input_actions_json, raw_phrase_actions_json,
        display_input_json, phrase_tokens_json, action_flags_json, plain_output,
        created_at, updated_at,
        COALESCE((SELECT starred FROM chord_feedback WHERE chord_id = chords.id), 0) AS feedback_starred
        """
    private static let HIDAttributionMigrationKey = "usage.hid_attribution.v1"

    public init(databaseURL: URL = AppSupportPaths.databaseURL, suggestionEngine: SuggestionEngine = SuggestionEngine()) throws {
        self.database = try SQLiteDatabase(url: databaseURL)
        self.suggestionEngine = suggestionEngine
    }

    public func isBootstrapped() throws -> Bool {
        try stringSetting(forKey: "bootstrap.completed_at") != nil
    }

    public func bootstrap(
        primarySource: DeviceSource,
        deviceChords: [DeviceChordRecord],
        nexusPath: URL?,
        freechorderPath: URL?
    ) throws {
        guard !deviceChords.isEmpty else {
            throw LibraryError.missingPrimaryDevice
        }
        guard try !isBootstrapped() else { return }

        try database.transaction {
            try upsertSource(primarySource)
            try importDeviceChords(deviceChords, source: primarySource)

            if let nexusPath {
                let bundle = try NexusImporter(path: nexusPath).load()
                try importStats(bundle)
            }

            if let freechorderPath, FileManager.default.fileExists(atPath: freechorderPath.path) {
                let reviewChords = try FreechorderImporter(path: freechorderPath).load()
                for chord in reviewChords {
                    try upsertChord(chord)
                }
            }

            try setSetting("bootstrap.primary_device_id", value: primarySource.id.uuidString)
            try setSetting("bootstrap.completed_at", value: String(Date().timeIntervalSince1970))
        }

        _ = try regenerateSuggestions(profile: .cc2A1)
        _ = try regenerateSuggestions(profile: .ansiQwerty)
    }

    public func allChords(search: String = "") throws -> [ChordEntry] {
        if search.isEmpty {
            return try fetchChords(
                """
                SELECT \(Self.chordColumns)
                FROM chords
                ORDER BY updated_at DESC, output ASC
                """
            )
        }

        let pattern = "%\(search.lowercased())%"
        return try fetchChords(
            """
            SELECT \(Self.chordColumns)
            FROM chords
            WHERE lower(output) LIKE ? OR lower(normalized_input) LIKE ? OR lower(source) LIKE ?
               OR lower(COALESCE(plain_output, '')) LIKE ?
               OR lower(COALESCE(action_flags_json, '')) LIKE ?
               OR lower(COALESCE(display_input_json, '')) LIKE ?
               OR lower(COALESCE(phrase_tokens_json, '')) LIKE ?
            ORDER BY updated_at DESC, output ASC
            """,
            bindings: [.text(pattern), .text(pattern), .text(pattern), .text(pattern), .text(pattern), .text(pattern), .text(pattern)]
        )
    }

    public func activeChords(for profile: ErgonomicProfile) throws -> [ChordEntry] {
        try fetchChords(
            """
            SELECT \(Self.chordColumns)
            FROM chords
            WHERE enabled = 1
              AND profile = ?
              AND deployment_target IN ('software', 'both')
            ORDER BY output ASC
            """,
            bindings: [.text(profile.rawValue)]
        )
    }

    public func deviceChords() throws -> [ChordEntry] {
        try fetchChords(
            """
            SELECT \(Self.chordColumns)
            FROM chords
            WHERE enabled = 1
              AND profile = ?
              AND deployment_target IN ('device', 'both')
            ORDER BY output ASC
            """,
            bindings: [.text(ErgonomicProfile.cc2A1.rawValue)]
        )
    }

    public func deviceChords(forOutput output: String) throws -> [ChordEntry] {
        let normalizedOutput = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedOutput.isEmpty else { return [] }

        return try fetchChords(
            """
            SELECT \(Self.chordColumns)
            FROM chords
            WHERE enabled = 1
              AND profile = ?
              AND deployment_target IN ('device', 'both')
              AND lower(COALESCE(NULLIF(plain_output, ''), output)) = ?
            ORDER BY normalized_input ASC, updated_at DESC
            """,
            bindings: [.text(ErgonomicProfile.cc2A1.rawValue), .text(normalizedOutput)]
        )
    }

    public func upsertChord(_ chord: ChordEntry, rawInput: String? = nil, rawOutput: String? = nil) throws {
        let rawRecord = enrichRawRecord(for: chord, rawInput: rawInput, rawOutput: rawOutput)
        let inputKeys = rawRecord?.display.inputTokens ?? chord.inputKeys
        let normalizedInput = ChordEntry.normalizeInputKeys(inputKeys)
        let output = rawRecord?.display.plainOutput ?? chord.output
        let displayInput = rawRecord?.display.inputTokens ?? chord.displayInput
        let phraseTokens = rawRecord?.display.phraseTokens ?? chord.phraseTokens
        let actionFlags = rawRecord?.display.flags ?? chord.actionFlags
        let plainOutput = rawRecord?.display.plainOutput ?? chord.plainOutput
        let inputIdentity = rawRecord?.encodedInput ?? chord.encodedInput ?? normalizedInput

        let storedInputJSON = try String(decoding: encoder.encode(inputKeys), as: UTF8.self)
        let rawInputActionsJSON = try optionalJSON(rawRecord?.inputActions ?? chord.rawInputActions)
        let rawPhraseActionsJSON = try optionalJSON(rawRecord?.phraseActions ?? chord.rawPhraseActions)
        let displayInputJSON = try String(decoding: encoder.encode(displayInput), as: UTF8.self)
        let phraseTokensJSON = try String(decoding: encoder.encode(phraseTokens), as: UTF8.self)
        let actionFlagsJSON = try String(decoding: encoder.encode(actionFlags.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue)), as: UTF8.self)
        let existingByID = try database.query(
            """
            SELECT id
            FROM chords
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(chord.id.uuidString)]
        ).first?.string("id")

        let existingBySlot = try database.query(
            """
            SELECT id
            FROM chords
            WHERE profile = ? AND deployment_target = ? AND input_identity = ?
            LIMIT 1
            """,
            bindings: [
                .text(chord.profile.rawValue),
                .text(chord.deploymentTarget.rawValue),
                .text(inputIdentity)
            ]
        ).first?.string("id")

        if let existingByID, let existingBySlot, existingByID != existingBySlot {
            throw LibraryError.sqliteError(
                "A chord already exists for \(chord.profile.displayName) / \(chord.deploymentTarget.rawValue) with input \(chord.normalizedInput)."
            )
        }

        let targetID = existingBySlot ?? existingByID ?? chord.id.uuidString

        if existingByID != nil || existingBySlot != nil {
            try database.execute(
                """
                UPDATE chords
                SET input_keys_json = ?,
                    normalized_input = ?,
                    output = ?,
                    profile = ?,
                    deployment_target = ?,
                    source = ?,
                    enabled = ?,
                    input_identity = ?,
                    raw_input = COALESCE(?, raw_input),
                    raw_output = COALESCE(?, raw_output),
                    raw_input_actions_json = COALESCE(?, raw_input_actions_json),
                    raw_phrase_actions_json = COALESCE(?, raw_phrase_actions_json),
                    display_input_json = ?,
                    phrase_tokens_json = ?,
                    action_flags_json = ?,
                    plain_output = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                bindings: [
                    .text(storedInputJSON),
                    .text(normalizedInput),
                    .text(output),
                    .text(chord.profile.rawValue),
                    .text(chord.deploymentTarget.rawValue),
                    .text(chord.source),
                    .bool(bool: chord.enabled),
                    .text(inputIdentity),
                    (rawRecord?.encodedInput ?? rawInput ?? chord.encodedInput).map(SQLiteValue.text) ?? .null,
                    (rawRecord?.encodedPhrase ?? rawOutput ?? chord.encodedPhrase).map(SQLiteValue.text) ?? .null,
                    rawInputActionsJSON.map(SQLiteValue.text) ?? .null,
                    rawPhraseActionsJSON.map(SQLiteValue.text) ?? .null,
                    .text(displayInputJSON),
                    .text(phraseTokensJSON),
                    .text(actionFlagsJSON),
                    plainOutput.map(SQLiteValue.text) ?? .null,
                    .double(chord.updatedAt.timeIntervalSince1970),
                    .text(targetID)
                ]
            )
            return
        }

        try database.execute(
            """
            INSERT INTO chords (
                id, input_keys_json, normalized_input, output, profile, deployment_target, source, enabled,
                input_identity, raw_input, raw_output, raw_input_actions_json, raw_phrase_actions_json,
                display_input_json, phrase_tokens_json, action_flags_json, plain_output,
                created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(chord.id.uuidString),
                .text(storedInputJSON),
                .text(normalizedInput),
                .text(output),
                .text(chord.profile.rawValue),
                .text(chord.deploymentTarget.rawValue),
                .text(chord.source),
                .bool(bool: chord.enabled),
                .text(inputIdentity),
                (rawRecord?.encodedInput ?? rawInput ?? chord.encodedInput).map(SQLiteValue.text) ?? .null,
                (rawRecord?.encodedPhrase ?? rawOutput ?? chord.encodedPhrase).map(SQLiteValue.text) ?? .null,
                rawInputActionsJSON.map(SQLiteValue.text) ?? .null,
                rawPhraseActionsJSON.map(SQLiteValue.text) ?? .null,
                .text(displayInputJSON),
                .text(phraseTokensJSON),
                .text(actionFlagsJSON),
                plainOutput.map(SQLiteValue.text) ?? .null,
                .double(chord.createdAt.timeIntervalSince1970),
                .double(chord.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    public func deleteChord(id: UUID) throws {
        try database.transaction {
            try database.execute("DELETE FROM chord_feedback WHERE chord_id = ?", bindings: [.text(id.uuidString)])
            try database.execute("DELETE FROM chords WHERE id = ?", bindings: [.text(id.uuidString)])
        }
    }

    public func setChordEnabled(id: UUID, enabled: Bool) throws {
        try database.execute(
            "UPDATE chords SET enabled = ?, updated_at = ? WHERE id = ?",
            bindings: [
                .bool(bool: enabled),
                .double(Date().timeIntervalSince1970),
                .text(id.uuidString)
            ]
        )
    }

    public func setChordStarred(id: UUID, starred: Bool, source: String = "user") throws {
        let now = Date().timeIntervalSince1970
        let existing = try database.query(
            "SELECT created_at FROM chord_feedback WHERE chord_id = ? LIMIT 1",
            bindings: [.text(id.uuidString)]
        ).first
        let createdAt = existing?.double("created_at") ?? now
        try database.execute(
            """
            INSERT OR REPLACE INTO chord_feedback (chord_id, starred, source, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(id.uuidString),
                .bool(bool: starred),
                .text(source),
                .double(createdAt),
                .double(now)
            ]
        )
    }

    public func chordFeedback(id: UUID) throws -> ChordFeedback? {
        try database.query(
            """
            SELECT chord_id, starred, source, created_at, updated_at
            FROM chord_feedback
            WHERE chord_id = ?
            LIMIT 1
            """,
            bindings: [.text(id.uuidString)]
        )
        .compactMap(decodeChordFeedback)
        .first
    }

    public func starredChordFeedback() throws -> [ChordFeedback] {
        try database.query(
            """
            SELECT chord_id, starred, source, created_at, updated_at
            FROM chord_feedback
            WHERE starred = 1
            ORDER BY updated_at DESC
            """
        )
        .compactMap(decodeChordFeedback)
    }

    @discardableResult
    public func importCharaChordFile(
        at url: URL,
        profile: ErgonomicProfile = .cc2A1,
        deploymentTarget: DeploymentTarget = .device,
        source: String? = nil,
        enabled: Bool = true
    ) throws -> Int {
        let imported = try CharaChordImporter(path: url).load(
            profile: profile,
            deploymentTarget: deploymentTarget,
            source: source,
            enabled: enabled
        )
        try database.transaction {
            for chord in imported {
                try upsertChord(chord)
            }
        }
        return imported.count
    }

    public func exportCharaChordFile(profile: ErgonomicProfile = .cc2A1) throws -> CharaChordFile {
        let chords = try fetchChords(
            """
            SELECT \(Self.chordColumns)
            FROM chords
            WHERE enabled = 1
              AND profile = ?
              AND deployment_target IN ('device', 'both')
            ORDER BY output ASC
            """,
            bindings: [.text(profile.rawValue)]
        )
        return CharaChordExporter.file(from: chords)
    }

    public func upsertWordStat(
        word: String,
        avgMs: Double,
        frequencyDelta: Int = 1,
        source: String,
        lastUsedAt: Date = .now
    ) throws {
        guard let processed = MultilingualWordProcessor.normalize(word) else { return }
        let lastUsed = lastUsedAt.timeIntervalSince1970
        try database.execute(
            """
            INSERT INTO word_stats (word, frequency, avg_ms, last_used_at, source, language)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(word, source) DO UPDATE SET
                avg_ms = ((word_stats.avg_ms * word_stats.frequency) +
                          (excluded.avg_ms * excluded.frequency)) /
                         (word_stats.frequency + excluded.frequency),
                frequency = word_stats.frequency + excluded.frequency,
                last_used_at = MAX(word_stats.last_used_at, excluded.last_used_at),
                language = excluded.language
            """,
            bindings: [
                .text(processed.text),
                .integer(Int64(frequencyDelta)),
                .double(avgMs),
                .double(lastUsed),
                .text(source),
                .text(processed.language.rawValue)
            ]
        )
    }

    public func recordWordUsage(
        word: String,
        avgMs: Double,
        source: UsageSource,
        frequencyDelta: Int = 1,
        lastUsedAt: Date = .now
    ) throws {
        guard let processed = MultilingualWordProcessor.normalize(word) else { return }

        try database.transaction {
            try upsertWordStat(
                word: processed.text,
                avgMs: avgMs,
                frequencyDelta: frequencyDelta,
                source: source.rawValue,
                lastUsedAt: lastUsedAt
            )
            try upsertDailyWordStat(
                word: processed.text,
                avgMs: avgMs,
                source: source,
                frequencyDelta: frequencyDelta,
                lastUsedAt: lastUsedAt
            )
        }
    }

    public func recordChordUsage(
        output: String,
        matchedChordId: UUID?,
        source: UsageSource,
        avgMs: Double,
        confidence: ChordUsageConfidence,
        ambiguityCount: Int = 0,
        frequencyDelta: Int = 1,
        lastUsedAt: Date = .now
    ) throws {
        let normalizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOutput.isEmpty else { return }

        try database.transaction {
            try upsertChordStat(
                output: normalizedOutput,
                source: source.rawValue,
                frequencyDelta: frequencyDelta,
                lastUsedAt: lastUsedAt
            )
            try upsertDailyChordStat(
                output: normalizedOutput,
                matchedChordId: matchedChordId,
                source: source,
                avgMs: avgMs,
                confidence: confidence,
                ambiguityCount: ambiguityCount,
                frequencyDelta: frequencyDelta,
                lastUsedAt: lastUsedAt
            )
        }
    }

    public func recordChordOutput(_ output: String, source: String = "software", lastUsedAt: Date = .now) throws {
        try upsertChordStat(output: output, source: source, frequencyDelta: 1, lastUsedAt: lastUsedAt)
    }

    public func wordStats(limit: Int = 200) throws -> [WordStat] {
        try fetchAggregatedWordStats(limit: limit)
    }

    public func chordStats(limit: Int = 200) throws -> [ChordStat] {
        let rows = try database.query(
            """
            SELECT output,
                   SUM(frequency) AS frequency,
                   MAX(last_used_at) AS last_used_at
            FROM chord_stats
            GROUP BY output
            ORDER BY frequency DESC, last_used_at DESC
            LIMIT ?
            """,
            bindings: [.integer(Int64(limit))]
        )

        return rows.compactMap { row in
            guard let output = row.string("output"),
                  let frequency = row.integer("frequency"),
                  let lastUsed = row.double("last_used_at") else {
                return nil
            }
            return ChordStat(output: output, frequency: Int(frequency), lastUsedAt: Date(timeIntervalSince1970: lastUsed), source: "aggregate")
        }
    }

    public func dailyWordUsage(days: Int = 30, limit: Int = 100) throws -> [DailyWordUsage] {
        let startDay = usageDay(for: Calendar.current.date(byAdding: .day, value: -(max(days, 1) - 1), to: Date()) ?? Date())
        let rows = try database.query(
            """
            SELECT day, word, source, language, SUM(frequency) AS frequency,
                   SUM(avg_ms * frequency) / SUM(frequency) AS avg_ms,
                   MAX(last_used_at) AS last_used_at
            FROM daily_word_stats
            WHERE day >= ?
            GROUP BY day, word, source, language
            ORDER BY frequency DESC, last_used_at DESC
            LIMIT ?
            """,
            bindings: [.text(startDay), .integer(Int64(limit))]
        )

        return rows.compactMap(decodeDailyWordUsage)
    }

    public func dailyChordUsage(days: Int = 30, limit: Int = 100) throws -> [DailyChordUsage] {
        let startDay = usageDay(for: Calendar.current.date(byAdding: .day, value: -(max(days, 1) - 1), to: Date()) ?? Date())
        let rows = try database.query(
            """
            SELECT day, output, matched_chord_id, source, SUM(frequency) AS frequency,
                   SUM(avg_ms * frequency) / SUM(frequency) AS avg_ms,
                   confidence, MAX(ambiguity_count) AS ambiguity_count,
                   MAX(last_used_at) AS last_used_at
            FROM daily_chord_stats
            WHERE day >= ?
            GROUP BY day, output, matched_chord_id, source, confidence
            ORDER BY frequency DESC, last_used_at DESC
            LIMIT ?
            """,
            bindings: [.text(startDay), .integer(Int64(limit))]
        )

        return rows.compactMap(decodeDailyChordUsage)
    }

    public func usageOverview(now: Date = .now) throws -> UsageOverview {
        let today = usageDay(for: now)
        let sevenDay = usageDay(for: Calendar.current.date(byAdding: .day, value: -6, to: now) ?? now)
        let thirtyDay = usageDay(for: Calendar.current.date(byAdding: .day, value: -29, to: now) ?? now)

        return UsageOverview(
            wordsToday: try usageFrequency(table: "daily_word_stats", sinceDay: today),
            chordsToday: try usageFrequency(table: "daily_chord_stats", sinceDay: today),
            words7Days: try usageFrequency(table: "daily_word_stats", sinceDay: sevenDay),
            chords7Days: try usageFrequency(table: "daily_chord_stats", sinceDay: sevenDay),
            words30Days: try usageFrequency(table: "daily_word_stats", sinceDay: thirtyDay),
            chords30Days: try usageFrequency(table: "daily_chord_stats", sinceDay: thirtyDay),
            wordsAllTime: try usageFrequency(table: "daily_word_stats", sinceDay: nil),
            chordsAllTime: try usageFrequency(table: "daily_chord_stats", sinceDay: nil)
        )
    }

    /// Ranks actually typed words and joins them to enabled M4G chord outputs.
    /// `days == nil` means all recorded history; otherwise the current day is
    /// included in the requested rolling window.
    public func wordCoverageReport(
        days: Int? = 30,
        language: WordLanguage? = nil,
        limitPerGroup: Int = 100,
        now: Date = .now
    ) throws -> WordCoverageReport {
        var predicates: [String] = []
        var bindings: [SQLiteValue] = []
        if let days {
            let start = Calendar.current.date(
                byAdding: .day,
                value: -(max(days, 1) - 1),
                to: now
            ) ?? now
            predicates.append("day >= ?")
            bindings.append(.text(usageDay(for: start)))
        }
        if let language {
            predicates.append("language = ?")
            bindings.append(.text(language.rawValue))
        }
        let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"

        let rows = try database.query(
            """
            SELECT word, language,
                   SUM(frequency) AS frequency,
                   SUM(avg_ms * frequency) / SUM(frequency) AS avg_ms,
                   MAX(last_used_at) AS last_used_at
            FROM daily_word_stats
            \(whereClause)
            GROUP BY word, language
            ORDER BY frequency DESC, last_used_at DESC, word ASC
            """,
            bindings: bindings
        )

        var chordsByWord: [String: [ChordEntry]] = [:]
        for chord in try deviceChords() {
            guard let plainOutput = chord.plainOutput else { continue }
            let outputWords = MultilingualWordProcessor.words(in: plainOutput)
            guard outputWords.count == 1, let outputWord = outputWords.first else { continue }
            chordsByWord[outputWord.text, default: []].append(chord)
        }
        for key in chordsByWord.keys {
            chordsByWord[key]?.sort { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.normalizedInput < rhs.normalizedInput }
                return lhs.updatedAt > rhs.updatedAt
            }
        }

        let words = rows.compactMap { row -> WordCoverageStat? in
            guard let word = row.string("word"),
                  let languageText = row.string("language"),
                  let frequency = row.integer("frequency"),
                  let avgMs = row.double("avg_ms"),
                  let lastUsedAt = row.double("last_used_at") else { return nil }
            return WordCoverageStat(
                word: word,
                language: WordLanguage(rawValue: languageText) ?? .other,
                frequency: Int(frequency),
                avgMs: avgMs,
                lastUsedAt: Date(timeIntervalSince1970: lastUsedAt),
                matchingChords: chordsByWord[word] ?? []
            )
        }

        let covered = words.filter(\.isCovered)
        let uncovered = words.filter { !$0.isCovered }
        return WordCoverageReport(
            totalOccurrences: words.reduce(0) { $0 + $1.frequency },
            coveredOccurrences: covered.reduce(0) { $0 + $1.frequency },
            uniqueWords: words.count,
            coveredUniqueWords: covered.count,
            coveredWords: Array(covered.prefix(max(limitPerGroup, 0))),
            uncoveredWords: Array(uncovered.prefix(max(limitPerGroup, 0)))
        )
    }

    public func twoKeyChordImpactReport(limit: Int = 200) throws -> [TwoKeyChordImpact] {
        let allDailyUsage = try database.query(
            """
            SELECT output, matched_chord_id, SUM(frequency) AS frequency,
                   SUM(CASE WHEN day >= ? THEN frequency ELSE 0 END) AS frequency_7,
                   SUM(CASE WHEN day >= ? THEN frequency ELSE 0 END) AS frequency_30,
                   MAX(last_used_at) AS last_used_at,
                   confidence,
                   MAX(ambiguity_count) AS ambiguity_count
            FROM daily_chord_stats
            GROUP BY output, matched_chord_id, confidence
            """,
            bindings: [
                .text(usageDay(for: Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())),
                .text(usageDay(for: Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()))
            ]
        )

        var usageByChordID: [UUID: (total: Int, seven: Int, thirty: Int, last: Date?, confidence: ChordUsageConfidence?, ambiguity: Int)] = [:]
        var usageByOutput: [String: (total: Int, seven: Int, thirty: Int, last: Date?, confidence: ChordUsageConfidence?, ambiguity: Int)] = [:]

        for row in allDailyUsage {
            let total = Int(row.integer("frequency") ?? 0)
            let seven = Int(row.integer("frequency_7") ?? 0)
            let thirty = Int(row.integer("frequency_30") ?? 0)
            let last = row.double("last_used_at").map(Date.init(timeIntervalSince1970:))
            let confidence = row.string("confidence").flatMap(ChordUsageConfidence.init(rawValue:))
            let ambiguity = Int(row.integer("ambiguity_count") ?? 0)
            let value = (total, seven, thirty, last, confidence, ambiguity)

            if let idText = row.string("matched_chord_id"), !idText.isEmpty, let id = UUID(uuidString: idText) {
                usageByChordID[id] = value
            } else if let output = row.string("output")?.lowercased(), !output.isEmpty {
                usageByOutput[output] = value
            }
        }

        return try deviceChords()
            .filter { chord in
                let input = chord.displayInput.isEmpty ? chord.inputKeys : chord.displayInput
                return input.count == 2
            }
            .map { chord in
                let outputKey = (chord.plainOutput ?? chord.output).lowercased()
                let usage = usageByChordID[chord.id] ?? usageByOutput[outputKey] ?? (0, 0, 0, nil, nil, 0)
                return TwoKeyChordImpact(
                    chord: chord,
                    totalFrequency: usage.total,
                    frequency7Days: usage.seven,
                    frequency30Days: usage.thirty,
                    lastUsedAt: usage.last,
                    confidence: usage.confidence,
                    ambiguityCount: usage.ambiguity
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalFrequency == rhs.totalFrequency {
                    return lhs.chord.output < rhs.chord.output
                }
                return lhs.totalFrequency > rhs.totalFrequency
            }
            .prefix(limit)
            .map { $0 }
    }

    private func upsertChordStat(output: String, source: String, frequencyDelta: Int, lastUsedAt: Date) throws {
        let lastUsed = lastUsedAt.timeIntervalSince1970
        let rows = try database.query(
            "SELECT frequency, last_used_at FROM chord_stats WHERE output = ? AND source = ?",
            bindings: [.text(output), .text(source)]
        )

        if let existing = rows.first {
            let frequency = Int(existing.integer("frequency") ?? 0) + frequencyDelta
            let newLastUsed = max(existing.double("last_used_at") ?? lastUsed, lastUsed)
            try database.execute(
                "UPDATE chord_stats SET frequency = ?, last_used_at = ? WHERE output = ? AND source = ?",
                bindings: [.integer(Int64(frequency)), .double(newLastUsed), .text(output), .text(source)]
            )
        } else {
            try database.execute(
                "INSERT INTO chord_stats (output, frequency, last_used_at, source) VALUES (?, ?, ?, ?)",
                bindings: [.text(output), .integer(Int64(frequencyDelta)), .double(lastUsed), .text(source)]
            )
        }
    }

    private func upsertDailyWordStat(
        word: String,
        avgMs: Double,
        source: UsageSource,
        frequencyDelta: Int,
        lastUsedAt: Date
    ) throws {
        guard let processed = MultilingualWordProcessor.normalize(word) else { return }
        let day = usageDay(for: lastUsedAt)
        let lastUsed = lastUsedAt.timeIntervalSince1970
        try database.execute(
            """
            INSERT INTO daily_word_stats (day, word, source, frequency, avg_ms, last_used_at, language)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(day, word, source) DO UPDATE SET
                avg_ms = ((daily_word_stats.avg_ms * daily_word_stats.frequency) +
                          (excluded.avg_ms * excluded.frequency)) /
                         (daily_word_stats.frequency + excluded.frequency),
                frequency = daily_word_stats.frequency + excluded.frequency,
                last_used_at = MAX(daily_word_stats.last_used_at, excluded.last_used_at),
                language = excluded.language
            """,
            bindings: [
                .text(day),
                .text(processed.text),
                .text(source.rawValue),
                .integer(Int64(frequencyDelta)),
                .double(avgMs),
                .double(lastUsed),
                .text(processed.language.rawValue)
            ]
        )
    }

    private func upsertDailyChordStat(
        output: String,
        matchedChordId: UUID?,
        source: UsageSource,
        avgMs: Double,
        confidence: ChordUsageConfidence,
        ambiguityCount: Int,
        frequencyDelta: Int,
        lastUsedAt: Date
    ) throws {
        let day = usageDay(for: lastUsedAt)
        let matchedID = matchedChordId?.uuidString ?? ""
        let lastUsed = lastUsedAt.timeIntervalSince1970
        let rows = try database.query(
            """
            SELECT frequency, avg_ms, last_used_at
            FROM daily_chord_stats
            WHERE day = ? AND output = ? AND matched_chord_id = ? AND source = ? AND confidence = ?
            """,
            bindings: [.text(day), .text(output), .text(matchedID), .text(source.rawValue), .text(confidence.rawValue)]
        )

        if let existing = rows.first {
            let oldFrequency = Int(existing.integer("frequency") ?? 0)
            let oldAvg = existing.double("avg_ms") ?? avgMs
            let newFrequency = oldFrequency + frequencyDelta
            let weightedAvg = ((oldAvg * Double(oldFrequency)) + (avgMs * Double(frequencyDelta))) / Double(max(newFrequency, 1))
            let newLastUsed = max(existing.double("last_used_at") ?? lastUsed, lastUsed)
            try database.execute(
                """
                UPDATE daily_chord_stats
                SET frequency = ?, avg_ms = ?, ambiguity_count = ?, last_used_at = ?
                WHERE day = ? AND output = ? AND matched_chord_id = ? AND source = ? AND confidence = ?
                """,
                bindings: [
                    .integer(Int64(newFrequency)),
                    .double(weightedAvg),
                    .integer(Int64(ambiguityCount)),
                    .double(newLastUsed),
                    .text(day),
                    .text(output),
                    .text(matchedID),
                    .text(source.rawValue),
                    .text(confidence.rawValue)
                ]
            )
        } else {
            try database.execute(
                """
                INSERT INTO daily_chord_stats (
                    day, output, matched_chord_id, source, frequency, avg_ms, confidence, ambiguity_count, last_used_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(day),
                    .text(output),
                    .text(matchedID),
                    .text(source.rawValue),
                    .integer(Int64(frequencyDelta)),
                    .double(avgMs),
                    .text(confidence.rawValue),
                    .integer(Int64(ambiguityCount)),
                    .double(lastUsed)
                ]
            )
        }
    }

    public func sources() throws -> [DeviceSource] {
        try database.query(
            "SELECT id, port_path, device_name, firmware, chord_count, is_primary FROM sources ORDER BY is_primary DESC, chord_count DESC"
        ).compactMap { row in
            guard let idText = row.string("id"),
                  let id = UUID(uuidString: idText),
                  let portPath = row.string("port_path"),
                  let deviceName = row.string("device_name"),
                  let firmware = row.string("firmware"),
                  let chordCount = row.integer("chord_count"),
                  let isPrimary = row.integer("is_primary") else {
                return nil
            }
            return DeviceSource(
                id: id,
                portPath: portPath,
                deviceName: deviceName,
                firmware: firmware,
                chordCount: Int(chordCount),
                isPrimary: isPrimary == 1
            )
        }
    }

    /// Removes usage that the old recorder attributed from text timing alone.
    /// Those rows cannot be distinguished from normal fast keyboard input after
    /// the fact, so they must not be mixed with physically confirmed HID usage.
    /// This intentionally checks for reintroduced rows even after migration in
    /// case an obsolete command-run process survived the app upgrade.
    @discardableResult
    public func migrateLegacyTimingInferencesIfNeeded() throws -> Bool {
        let legacyRowCount = try database.query(
            """
            SELECT
                (SELECT COUNT(*) FROM word_stats WHERE source = 'm4g_output_inferred') +
                (SELECT COUNT(*) FROM chord_stats WHERE source = 'm4g_output_inferred') +
                (SELECT COUNT(*) FROM daily_word_stats WHERE source = 'm4g_output_inferred') +
                (SELECT COUNT(*) FROM daily_chord_stats WHERE source = 'm4g_output_inferred')
                AS legacy_row_count
            """
        ).first?.integer("legacy_row_count") ?? 0
        let migrationCompleted = try stringSetting(forKey: Self.HIDAttributionMigrationKey) == "complete"
        guard !migrationCompleted || legacyRowCount > 0 else {
            return false
        }

        try database.transaction {
            try database.execute("DELETE FROM word_stats WHERE source = 'm4g_output_inferred'")
            try database.execute("DELETE FROM chord_stats WHERE source = 'm4g_output_inferred'")
            try database.execute("DELETE FROM daily_word_stats WHERE source = 'm4g_output_inferred'")
            try database.execute("DELETE FROM daily_chord_stats WHERE source = 'm4g_output_inferred'")
            try database.execute("DELETE FROM suggestions")
        }
        for profile in ErgonomicProfile.allCases {
            _ = try regenerateSuggestions(profile: profile)
        }
        try setSetting(Self.HIDAttributionMigrationKey, value: "complete")
        return true
    }

    public func bannedInputs() throws -> Set<String> {
        let rows = try database.query("SELECT value FROM bans WHERE kind = 'chord'")
        return Set(rows.compactMap { $0.string("value") })
    }

    public func banChordInput(_ normalizedInput: String) throws {
        try database.execute(
            "INSERT OR REPLACE INTO bans (kind, value, created_at) VALUES ('chord', ?, ?)",
            bindings: [.text(normalizedInput.lowercased()), .double(Date().timeIntervalSince1970)]
        )
    }

    public func regenerateSuggestions(profile: ErgonomicProfile, limit: Int = 50) throws -> [Suggestion] {
        let words = try fetchAggregatedWordStats(limit: 500)
        let existingChords: [ChordEntry]

        switch profile {
        case .cc2A1:
            existingChords = try fetchChords(
                """
                SELECT \(Self.chordColumns)
                FROM chords
                WHERE enabled = 1
                  AND profile = ?
                  AND deployment_target IN ('device', 'both')
                """,
                bindings: [.text(profile.rawValue)]
            )
        default:
            existingChords = try fetchChords(
                """
                SELECT \(Self.chordColumns)
                FROM chords
                WHERE enabled = 1
                  AND profile = ?
                  AND deployment_target IN ('software', 'both')
                """,
                bindings: [.text(profile.rawValue)]
            )
        }

        let suggestions = suggestionEngine.generateSuggestions(
            profile: profile,
            words: words,
            existingChords: existingChords,
            availableChords: try allEnabledChords(),
            bannedInputs: try bannedInputs(),
            limit: limit
        )

        try database.transaction {
            try database.execute("DELETE FROM suggestions WHERE profile = ?", bindings: [.text(profile.rawValue)])
            for suggestion in suggestions {
                let candidatesJSON = try String(decoding: encoder.encode(suggestion.candidates), as: UTF8.self)
                try database.execute(
                    """
                    INSERT INTO suggestions (
                        word, profile, candidates_json, priority_score, accepted_chord_id, banned_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(suggestion.word),
                        .text(suggestion.profile.rawValue),
                        .text(candidatesJSON),
                        .double(suggestion.priorityScore),
                        suggestion.acceptedChordId.map { .text($0.uuidString) } ?? .null,
                        suggestion.bannedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                        .double(Date().timeIntervalSince1970)
                    ]
                )
            }
        }

        return suggestions
    }

    private func allEnabledChords() throws -> [ChordEntry] {
        try fetchChords(
            """
            SELECT \(Self.chordColumns)
            FROM chords
            WHERE enabled = 1
            """
        )
    }

    public func adviseChord(
        for word: String,
        profile: ErgonomicProfile = .cc2A1,
        allowExistingOutput: Bool = false,
        limit: Int = 10
    ) throws -> [Candidate] {
        let existingChords: [ChordEntry]
        switch profile {
        case .cc2A1:
            existingChords = try deviceChords()
        default:
            existingChords = try activeChords(for: profile)
        }
        return suggestionEngine.adviseChord(
            for: word,
            profile: profile,
            existingChords: existingChords,
            bannedInputs: try bannedInputs(),
            allowReplacingOutput: allowExistingOutput,
            limit: limit
        )
    }

    public func diagnoseRejectedChordCandidates(
        for word: String,
        profile: ErgonomicProfile = .cc2A1,
        allowExistingOutput: Bool = false,
        limit: Int = 10
    ) throws -> [Candidate] {
        let existingChords: [ChordEntry]
        switch profile {
        case .cc2A1:
            existingChords = try deviceChords()
        default:
            existingChords = try activeChords(for: profile)
        }
        return suggestionEngine.diagnoseRejectedCandidates(
            for: word,
            profile: profile,
            existingChords: existingChords,
            bannedInputs: try bannedInputs(),
            allowReplacingOutput: allowExistingOutput,
            limit: limit
        )
    }

    public func listSuggestions(profile: ErgonomicProfile, limit: Int = 50) throws -> [Suggestion] {
        let rows = try database.query(
            """
            SELECT word, profile, candidates_json, priority_score, accepted_chord_id, banned_at
            FROM suggestions
            WHERE profile = ?
            ORDER BY priority_score DESC, word ASC
            LIMIT ?
            """,
            bindings: [.text(profile.rawValue), .integer(Int64(limit))]
        )

        return try rows.compactMap { row in
            guard let word = row.string("word"),
                  let profileText = row.string("profile"),
                  let suggestionProfile = ErgonomicProfile(rawValue: profileText),
                  let candidatesJSON = row.string("candidates_json"),
                  let priorityScore = row.double("priority_score") else {
                return nil
            }
            let candidates = try decoder.decode([Candidate].self, from: Data(candidatesJSON.utf8))
            let accepted = row.string("accepted_chord_id").flatMap(UUID.init(uuidString:))
            let bannedAt = row.double("banned_at").map(Date.init(timeIntervalSince1970:))
            return Suggestion(
                word: word,
                profile: suggestionProfile,
                candidates: candidates,
                priorityScore: priorityScore,
                acceptedChordId: accepted,
                bannedAt: bannedAt
            )
        }
    }

    public func setSetting(_ key: String, value: String) throws {
        try database.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
            bindings: [.text(key), .text(value)]
        )
    }

    public func stringSetting(forKey key: String) throws -> String? {
        try database.query(
            "SELECT value FROM settings WHERE key = ?",
            bindings: [.text(key)]
        ).first?.string("value")
    }

    private func upsertSource(_ source: DeviceSource) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO sources (id, port_path, device_name, firmware, chord_count, is_primary)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(source.id.uuidString),
                .text(source.portPath),
                .text(source.deviceName),
                .text(source.firmware),
                .integer(Int64(source.chordCount)),
                .bool(bool: source.isPrimary)
            ]
        )
    }

    private func importDeviceChords(_ chords: [DeviceChordRecord], source: DeviceSource) throws {
        for record in chords {
            let chord = ChordEntry(
                inputKeys: record.inputKeys,
                output: record.output,
                rawInputActions: record.rawInputActions,
                rawPhraseActions: record.rawPhraseActions,
                encodedInput: record.rawInput,
                encodedPhrase: record.rawOutput,
                profile: .cc2A1,
                deploymentTarget: .device,
                source: source.deviceName,
                enabled: true
            )
            try upsertChord(chord, rawInput: record.rawInput, rawOutput: record.rawOutput)
        }
    }

    private func importStats(_ bundle: ImportedStatsBundle) throws {
        for word in bundle.words {
            try upsertWordStat(
                word: word.word,
                avgMs: word.avgMs,
                frequencyDelta: word.frequency,
                source: UsageSource.nexusImport.rawValue,
                lastUsedAt: word.lastUsedAt
            )
            try upsertDailyWordStat(
                word: word.word.lowercased(),
                avgMs: word.avgMs,
                source: .nexusImport,
                frequencyDelta: word.frequency,
                lastUsedAt: word.lastUsedAt
            )
        }
        for chord in bundle.chords {
            try upsertChordStat(
                output: chord.output,
                source: UsageSource.nexusImport.rawValue,
                frequencyDelta: chord.frequency,
                lastUsedAt: chord.lastUsedAt
            )
            try upsertDailyChordStat(
                output: chord.output,
                matchedChordId: nil,
                source: .nexusImport,
                avgMs: 0,
                confidence: .nexusImport,
                ambiguityCount: 0,
                frequencyDelta: chord.frequency,
                lastUsedAt: chord.lastUsedAt
            )
        }
    }

    private func fetchAggregatedWordStats(limit: Int) throws -> [WordStat] {
        let rows = try database.query(
            """
            SELECT word,
                   SUM(frequency) AS frequency,
                   SUM(avg_ms * frequency) / SUM(frequency) AS avg_ms,
                   MAX(last_used_at) AS last_used_at,
                   MAX(language) AS language
            FROM word_stats
            GROUP BY word
            ORDER BY frequency DESC, last_used_at DESC
            LIMIT ?
            """,
            bindings: [.integer(Int64(limit))]
        )

        return rows.compactMap { row in
            guard let word = row.string("word"),
                  let frequency = row.integer("frequency"),
                  let avgMs = row.double("avg_ms"),
                  let lastUsedAt = row.double("last_used_at"),
                  let languageText = row.string("language") else {
                return nil
            }
            return WordStat(
                word: word,
                frequency: Int(frequency),
                avgMs: avgMs,
                lastUsedAt: Date(timeIntervalSince1970: lastUsedAt),
                source: "aggregate",
                language: WordLanguage(rawValue: languageText) ?? .other
            )
        }
    }

    private func fetchChords(_ sql: String, bindings: [SQLiteValue] = []) throws -> [ChordEntry] {
        try database.query(sql, bindings: bindings).compactMap { row in
            guard let idText = row.string("id"),
                  let id = UUID(uuidString: idText),
                  let inputJSON = row.string("input_keys_json"),
                  let inputKeys = try? decoder.decode([String].self, from: Data(inputJSON.utf8)),
                  let normalizedInput = row.string("normalized_input"),
                  let output = row.string("output"),
                  let profileText = row.string("profile"),
                  let profile = ErgonomicProfile(rawValue: profileText),
                  let deploymentText = row.string("deployment_target"),
                  let deployment = DeploymentTarget(rawValue: deploymentText),
                  let source = row.string("source"),
                  let enabledInt = row.integer("enabled"),
                  let createdAt = row.double("created_at"),
                  let updatedAt = row.double("updated_at") else {
                return nil
            }

            let encodedInput = row.string("raw_input")
            let encodedPhrase = row.string("raw_output")
            let rawInputActions = try decodeOptionalArray(Int.self, row.string("raw_input_actions_json"))
            let rawPhraseActions = try decodeOptionalArray(Int.self, row.string("raw_phrase_actions_json"))
            let rawRecord: RawChordRecord?
            if let rawInputActions, let rawPhraseActions {
                rawRecord = RawChordRecord(inputActions: rawInputActions, phraseActions: rawPhraseActions)
            } else if let encodedInput, let encodedPhrase {
                rawRecord = RawChordRecord(encodedInput: encodedInput, encodedPhrase: encodedPhrase)
            } else {
                rawRecord = nil
            }

            let displayInput = try decodeOptionalArray(String.self, row.string("display_input_json")) ?? rawRecord?.display.inputTokens ?? inputKeys
            let phraseTokens = try decodeOptionalArray(String.self, row.string("phrase_tokens_json")) ?? rawRecord?.display.phraseTokens ?? output.map { String($0) }
            let flagNames = try decodeOptionalArray(String.self, row.string("action_flags_json")) ?? []
            let decodedFlags = Set(flagNames.compactMap(ChordFlag.init(rawValue:)))
            let flags = decodedFlags.isEmpty ? rawRecord?.display.flags ?? [] : decodedFlags
            let plainOutput = row.string("plain_output") ?? rawRecord?.display.plainOutput
            let displayOutput = plainOutput ?? (rawRecord == nil ? output : rawRecord?.display.displayOutput ?? output)

            return ChordEntry(
                id: id,
                inputKeys: inputKeys,
                normalizedInput: normalizedInput,
                output: displayOutput,
                rawInputActions: rawInputActions ?? rawRecord?.inputActions,
                rawPhraseActions: rawPhraseActions ?? rawRecord?.phraseActions,
                encodedInput: encodedInput,
                encodedPhrase: encodedPhrase,
                displayInput: displayInput,
                phraseTokens: phraseTokens,
                actionFlags: flags,
                plainOutput: plainOutput,
                profile: profile,
                deploymentTarget: deployment,
                source: source,
                enabled: enabledInt == 1,
                isStarred: (row.integer("feedback_starred") ?? 0) == 1,
                createdAt: Date(timeIntervalSince1970: createdAt),
                updatedAt: Date(timeIntervalSince1970: updatedAt)
            )
        }
    }

    private func decodeChordFeedback(_ row: SQLiteRow) -> ChordFeedback? {
        guard let chordIDText = row.string("chord_id"),
              let chordID = UUID(uuidString: chordIDText),
              let starred = row.integer("starred"),
              let source = row.string("source"),
              let createdAt = row.double("created_at"),
              let updatedAt = row.double("updated_at") else {
            return nil
        }
        return ChordFeedback(
            chordId: chordID,
            starred: starred == 1,
            source: source,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private func decodeDailyWordUsage(_ row: SQLiteRow) -> DailyWordUsage? {
        guard let day = row.string("day"),
              let word = row.string("word"),
              let sourceText = row.string("source"),
              let source = UsageSource(rawValue: sourceText),
              let frequency = row.integer("frequency"),
              let avgMs = row.double("avg_ms"),
              let lastUsedAt = row.double("last_used_at"),
              let languageText = row.string("language") else {
            return nil
        }

        return DailyWordUsage(
            day: day,
            word: word,
            source: source,
            frequency: Int(frequency),
            avgMs: avgMs,
            lastUsedAt: Date(timeIntervalSince1970: lastUsedAt),
            language: WordLanguage(rawValue: languageText) ?? .other
        )
    }

    private func decodeDailyChordUsage(_ row: SQLiteRow) -> DailyChordUsage? {
        guard let day = row.string("day"),
              let output = row.string("output"),
              let sourceText = row.string("source"),
              let source = UsageSource(rawValue: sourceText),
              let frequency = row.integer("frequency"),
              let avgMs = row.double("avg_ms"),
              let confidenceText = row.string("confidence"),
              let confidence = ChordUsageConfidence(rawValue: confidenceText),
              let ambiguityCount = row.integer("ambiguity_count"),
              let lastUsedAt = row.double("last_used_at") else {
            return nil
        }

        let matchedChordId = row.string("matched_chord_id")
            .flatMap { $0.isEmpty ? nil : UUID(uuidString: $0) }
        return DailyChordUsage(
            day: day,
            output: output,
            matchedChordId: matchedChordId,
            source: source,
            frequency: Int(frequency),
            avgMs: avgMs,
            confidence: confidence,
            ambiguityCount: Int(ambiguityCount),
            lastUsedAt: Date(timeIntervalSince1970: lastUsedAt)
        )
    }

    private func usageFrequency(table: String, sinceDay: String?) throws -> Int {
        let allowedTables = Set(["daily_word_stats", "daily_chord_stats"])
        guard allowedTables.contains(table) else { return 0 }

        let rows: [SQLiteRow]
        if let sinceDay {
            rows = try database.query(
                "SELECT COALESCE(SUM(frequency), 0) AS frequency FROM \(table) WHERE day >= ?",
                bindings: [.text(sinceDay)]
            )
        } else {
            rows = try database.query("SELECT COALESCE(SUM(frequency), 0) AS frequency FROM \(table)")
        }
        return Int(rows.first?.integer("frequency") ?? 0)
    }

    private func usageDay(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    private func optionalJSON<T: Encodable>(_ value: T?) throws -> String? {
        guard let value else { return nil }
        return try String(decoding: encoder.encode(value), as: UTF8.self)
    }

    private func decodeOptionalArray<T: Decodable>(_ type: T.Type, _ json: String?) throws -> [T]? {
        guard let json, !json.isEmpty else { return nil }
        return try decoder.decode([T].self, from: Data(json.utf8))
    }

    private func enrichRawRecord(for chord: ChordEntry, rawInput: String?, rawOutput: String?) -> RawChordRecord? {
        if let rawInput, let rawOutput, rawInput.count == 32 {
            return RawChordRecord(encodedInput: rawInput, encodedPhrase: rawOutput)
        }
        if let rawInputActions = chord.rawInputActions, let rawPhraseActions = chord.rawPhraseActions {
            return RawChordRecord(inputActions: rawInputActions, phraseActions: rawPhraseActions)
        }
        if let encodedInput = chord.encodedInput, let encodedPhrase = chord.encodedPhrase, encodedInput.count == 32 {
            return RawChordRecord(encodedInput: encodedInput, encodedPhrase: encodedPhrase)
        }
        if chord.deploymentTarget == .device || chord.deploymentTarget == .both {
            guard let inputActions = ActionCodec.chordActions(forTokens: chord.inputKeys) else {
                return nil
            }
            return RawChordRecord(
                inputActions: inputActions,
                phraseActions: ActionCodec.phraseActions(forPlainText: chord.output)
            )
        }
        return nil
    }
}

// MARK: - Growth planning and practice

extension LibraryService {
    private static let growthSkipBanKind = "grow_skip"
    private static let learnedChordsSettingKey = "practice.learned_chord_ids.v1"
    /// Chord sources that mean "added from Chordsmith", as opposed to the
    /// library imported from the device.
    private static let addedChordSources = ["grow", "advisor", "quick_add", "suggestion", "user"]

    /// Recorded words in the window, split into letter-by-letter and chorded
    /// uses. Nexus imports carry no timing split and are left out.
    public func wordSourceUsage(days: Int?, now: Date = .now) throws -> [WordSourceUsage] {
        var predicates = ["source != ?"]
        var bindings: [SQLiteValue] = [.text(UsageSource.nexusImport.rawValue)]
        if let days {
            let start = Calendar.current.date(byAdding: .day, value: -(max(days, 1) - 1), to: now) ?? now
            predicates.append("day >= ?")
            bindings.append(.text(usageDay(for: start)))
        }
        let rows = try database.query(
            """
            SELECT word, language, source,
                   SUM(frequency) AS frequency,
                   SUM(avg_ms * frequency) / SUM(frequency) AS avg_ms,
                   MAX(last_used_at) AS last_used_at
            FROM daily_word_stats
            WHERE \(predicates.joined(separator: " AND "))
            GROUP BY word, language, source
            """,
            bindings: bindings
        )

        struct Accumulator {
            var language: WordLanguage
            var typed = 0
            var keyboard = 0
            var chorded = 0
            var typedTime = 0.0
            var allTime = 0.0
            var lastUsed = 0.0
        }
        let typedSources = Set(UsageSource.typedSources.map(\.rawValue))
        let chordedSources = Set(UsageSource.chordedSources.map(\.rawValue))
        var byWord: [String: Accumulator] = [:]
        for row in rows {
            guard let word = row.string("word"),
                  let source = row.string("source"),
                  let frequency = row.integer("frequency").map(Int.init),
                  let avgMs = row.double("avg_ms") else { continue }
            let language = WordLanguage(rawValue: row.string("language") ?? "") ?? .other
            var entry = byWord[word] ?? Accumulator(language: language)
            if typedSources.contains(source) {
                entry.typed += frequency
                entry.typedTime += avgMs * Double(frequency)
                if source == UsageSource.keyboard.rawValue {
                    entry.keyboard += frequency
                }
            } else if chordedSources.contains(source) {
                entry.chorded += frequency
            }
            entry.allTime += avgMs * Double(frequency)
            entry.lastUsed = max(entry.lastUsed, row.double("last_used_at") ?? 0)
            byWord[word] = entry
        }

        return byWord.map { word, entry in
            let total = entry.typed + entry.chorded
            let typedAvg = entry.typed > 0
                ? entry.typedTime / Double(entry.typed)
                : entry.allTime / Double(max(total, 1))
            return WordSourceUsage(
                word: word,
                language: entry.language,
                typedFrequency: entry.typed,
                keyboardFrequency: entry.keyboard,
                chordedFrequency: entry.chorded,
                typedAvgMs: typedAvg,
                lastUsedAt: Date(timeIntervalSince1970: entry.lastUsed)
            )
        }
        .sorted { $0.frequency == $1.frequency ? $0.word < $1.word : $0.frequency > $1.frequency }
    }

    /// Ranks the words that cost you the most time without a chord and gives
    /// each a conflict-free chord, ready to stage as one batch.
    public func growthPlan(
        profile: ErgonomicProfile = .cc2A1,
        days: Int = 30,
        limit: Int = 100,
        now: Date = .now
    ) throws -> GrowthPlan {
        let existingChords: [ChordEntry]
        switch profile {
        case .cc2A1:
            existingChords = try deviceChords()
        default:
            existingChords = try activeChords(for: profile)
        }
        return GrowthPlanner(engine: suggestionEngine).plan(
            usage: try wordSourceUsage(days: days, now: now),
            profile: profile,
            existingChords: existingChords,
            bannedInputs: try bannedInputs(),
            skippedWords: try skippedGrowthWords(),
            dictionary: GrowthPlanner.loadSystemDictionary(),
            windowDays: days,
            limit: limit
        )
    }

    public func skippedGrowthWords() throws -> Set<String> {
        let rows = try database.query(
            "SELECT value FROM bans WHERE kind = ?",
            bindings: [.text(Self.growthSkipBanKind)]
        )
        return Set(rows.compactMap { $0.string("value") })
    }

    public func setGrowthWordSkipped(_ word: String, skipped: Bool) throws {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        if skipped {
            try database.execute(
                "INSERT OR REPLACE INTO bans (kind, value, created_at) VALUES (?, ?, ?)",
                bindings: [.text(Self.growthSkipBanKind), .text(normalized), .double(Date().timeIntervalSince1970)]
            )
        } else {
            try database.execute(
                "DELETE FROM bans WHERE kind = ? AND value = ?",
                bindings: [.text(Self.growthSkipBanKind), .text(normalized)]
            )
        }
    }

    public func learnedChordIDs() throws -> Set<UUID> {
        guard let value = try stringSetting(forKey: Self.learnedChordsSettingKey),
              let ids = try? decoder.decode([String].self, from: Data(value.utf8)) else {
            return []
        }
        return Set(ids.compactMap(UUID.init(uuidString:)))
    }

    public func setChordLearned(id: UUID, learned: Bool) throws {
        var ids = try learnedChordIDs()
        if learned {
            ids.insert(id)
        } else {
            ids.remove(id)
        }
        let json = try String(decoding: encoder.encode(ids.map(\.uuidString).sorted()), as: UTF8.self)
        try setSetting(Self.learnedChordsSettingKey, value: json)
    }

    /// What to practice: chords you have but did not use, typos of chorded
    /// words, and recently added chords you have not adopted yet.
    public func practiceReport(
        days: Int = 7,
        learningDays: Int = 30,
        now: Date = .now
    ) throws -> PracticeReport {
        let usage = try wordSourceUsage(days: days, now: now)
        let chords = try deviceChords()
        let chordsByWord = GrowthPlanner.chordsByOutputWord(chords)
        let knownFrequency = Dictionary(usage.map { ($0.word, $0.frequency) }, uniquingKeysWith: +)
        let dictionary = GrowthPlanner.loadSystemDictionary()

        var forgotten: [ForgottenChord] = []
        var typos: [TypoFinding] = []
        // Single letters are one keypress; there is nothing to gain by chording them.
        for entry in usage where entry.language == .english && entry.typedFrequency > 0 && entry.word.count >= 2 {
            if let wordChords = chordsByWord[entry.word] {
                forgotten.append(
                    ForgottenChord(
                        word: entry.word,
                        chordInputs: wordChords.map(GrowthPlanner.displayInput),
                        typedFrequency: entry.typedFrequency,
                        keyboardFrequency: entry.keyboardFrequency,
                        chordedFrequency: entry.chordedFrequency,
                        typedAvgMs: entry.typedAvgMs
                    )
                )
            } else if entry.word.count >= 3,
                      entry.typedFrequency >= 2,
                      let intended = GrowthPlanner.intendedWord(
                          forTypo: entry.word,
                          frequency: entry.typedFrequency,
                          chordedWords: chordsByWord,
                          knownFrequency: knownFrequency,
                          dictionary: dictionary
                      ),
                      let intendedChord = chordsByWord[intended]?.first {
                typos.append(
                    TypoFinding(
                        typo: entry.word,
                        intended: intended,
                        frequency: entry.typedFrequency,
                        intendedChordInput: GrowthPlanner.displayInput(intendedChord)
                    )
                )
            }
        }
        forgotten.sort { lhs, rhs in
            let lhsCost = Double(lhs.typedFrequency) * min(lhs.typedAvgMs, GrowthPlanner.avgMsCap)
            let rhsCost = Double(rhs.typedFrequency) * min(rhs.typedAvgMs, GrowthPlanner.avgMsCap)
            return lhsCost == rhsCost ? lhs.word < rhs.word : lhsCost > rhsCost
        }
        typos.sort { $0.frequency == $1.frequency ? $0.typo < $1.typo : $0.frequency > $1.frequency }

        let learned = try learnedChordIDs()
        let learningStart = Calendar.current.date(byAdding: .day, value: -max(learningDays, 1), to: now) ?? now
        let recent = chords
            .filter { Self.addedChordSources.contains($0.source) && $0.createdAt >= learningStart }
            .sorted { $0.createdAt > $1.createdAt }
        var learning: [LearningChord] = []
        var learnedCount = 0
        for chord in recent {
            if learned.contains(chord.id) {
                learnedCount += 1
                continue
            }
            let word = (chord.plainOutput ?? chord.output).lowercased()
            let addedDay = usageDay(for: chord.createdAt)
            let chorded = try database.query(
                """
                SELECT COALESCE(SUM(frequency), 0) AS frequency
                FROM daily_chord_stats
                WHERE day >= ? AND (matched_chord_id = ? OR lower(output) = ?)
                """,
                bindings: [.text(addedDay), .text(chord.id.uuidString), .text(word)]
            ).first?.integer("frequency") ?? 0
            let typed = try database.query(
                """
                SELECT COALESCE(SUM(frequency), 0) AS frequency
                FROM daily_word_stats
                WHERE day >= ? AND word = ? AND source IN (?, ?)
                """,
                bindings: [
                    .text(addedDay),
                    .text(word),
                    .text(UsageSource.keyboard.rawValue),
                    .text(UsageSource.m4gTyping.rawValue)
                ]
            ).first?.integer("frequency") ?? 0
            learning.append(LearningChord(chord: chord, chordedSinceAdded: Int(chorded), typedSinceAdded: Int(typed)))
        }

        let keyboardWords = usage.reduce(0) { $0 + $1.keyboardFrequency }
        let typedWords = usage.reduce(0) { $0 + $1.typedFrequency }
        return PracticeReport(
            windowDays: days,
            forgotten: Array(forgotten.prefix(80)),
            typos: Array(typos.prefix(40)),
            learning: learning,
            learnedCount: learnedCount,
            keyboardWords: keyboardWords,
            m4gTypedWords: typedWords - keyboardWords,
            chordedWords: usage.reduce(0) { $0 + $1.chordedFrequency }
        )
    }
}
