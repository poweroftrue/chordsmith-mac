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

    public func upsertWordStat(word: String, avgMs: Double, frequencyDelta: Int = 1, source: String) throws {
        let normalizedWord = word.lowercased()
        let rows = try database.query(
            "SELECT frequency, avg_ms FROM word_stats WHERE word = ? AND source = ?",
            bindings: [.text(normalizedWord), .text(source)]
        )
        let now = Date().timeIntervalSince1970

        if let existing = rows.first {
            let oldFrequency = Int(existing.integer("frequency") ?? 0)
            let oldAvg = existing.double("avg_ms") ?? avgMs
            let newFrequency = oldFrequency + frequencyDelta
            let weightedAvg = ((oldAvg * Double(oldFrequency)) + (avgMs * Double(frequencyDelta))) / Double(max(newFrequency, 1))
            try database.execute(
                """
                UPDATE word_stats
                SET frequency = ?, avg_ms = ?, last_used_at = ?
                WHERE word = ? AND source = ?
                """,
                bindings: [
                    .integer(Int64(newFrequency)),
                    .double(weightedAvg),
                    .double(now),
                    .text(normalizedWord),
                    .text(source)
                ]
            )
        } else {
            try database.execute(
                """
                INSERT INTO word_stats (word, frequency, avg_ms, last_used_at, source)
                VALUES (?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(normalizedWord),
                    .integer(Int64(frequencyDelta)),
                    .double(avgMs),
                    .double(now),
                    .text(source)
                ]
            )
        }
    }

    public func recordChordOutput(_ output: String, source: String = "software") throws {
        let now = Date().timeIntervalSince1970
        let rows = try database.query(
            "SELECT frequency FROM chord_stats WHERE output = ? AND source = ?",
            bindings: [.text(output), .text(source)]
        )

        if let existing = rows.first {
            let frequency = Int(existing.integer("frequency") ?? 0) + 1
            try database.execute(
                "UPDATE chord_stats SET frequency = ?, last_used_at = ? WHERE output = ? AND source = ?",
                bindings: [.integer(Int64(frequency)), .double(now), .text(output), .text(source)]
            )
        } else {
            try database.execute(
                "INSERT INTO chord_stats (output, frequency, last_used_at, source) VALUES (?, ?, ?, ?)",
                bindings: [.text(output), .integer(1), .double(now), .text(source)]
            )
        }
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

    public func bannedWords() throws -> Set<String> {
        let rows = try database.query("SELECT value FROM bans WHERE kind = 'word'")
        return Set(rows.compactMap { $0.string("value") })
    }

    public func bannedInputs() throws -> Set<String> {
        let rows = try database.query("SELECT value FROM bans WHERE kind = 'chord'")
        return Set(rows.compactMap { $0.string("value") })
    }

    public func banWord(_ word: String) throws {
        try database.execute(
            "INSERT OR REPLACE INTO bans (kind, value, created_at) VALUES ('word', ?, ?)",
            bindings: [.text(word.lowercased()), .double(Date().timeIntervalSince1970)]
        )
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
            bannedWords: try bannedWords(),
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
            try upsertWordStat(word: word.word, avgMs: word.avgMs, frequencyDelta: word.frequency, source: word.source)
        }
        for chord in bundle.chords {
            for _ in 0..<max(chord.frequency, 1) {
                try recordChordOutput(chord.output, source: chord.source)
            }
        }
    }

    private func fetchAggregatedWordStats(limit: Int) throws -> [WordStat] {
        let rows = try database.query(
            """
            SELECT word,
                   SUM(frequency) AS frequency,
                   SUM(avg_ms * frequency) / SUM(frequency) AS avg_ms,
                   MAX(last_used_at) AS last_used_at
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
                  let lastUsedAt = row.double("last_used_at") else {
                return nil
            }
            return WordStat(
                word: word,
                frequency: Int(frequency),
                avgMs: avgMs,
                lastUsedAt: Date(timeIntervalSince1970: lastUsedAt),
                source: "aggregate"
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
