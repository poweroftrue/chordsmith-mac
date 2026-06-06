import Foundation
import SQLite3

public struct ImportedStatsBundle: Sendable {
    public let words: [WordStat]
    public let chords: [ChordStat]

    public init(words: [WordStat], chords: [ChordStat]) {
        self.words = words
        self.chords = chords
    }
}

public enum ImporterError: LocalizedError {
    case missingFile(URL)
    case invalidFormat(String)
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let url):
            return "Missing import file at \(url.path)."
        case .invalidFormat(let message):
            return message
        case .sqlite(let message):
            return message
        }
    }
}

public struct NexusImporter {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public func load() throws -> ImportedStatsBundle {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ImporterError.missingFile(path)
        }

        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK, let db else {
            throw ImporterError.sqlite("Unable to open nexus database.")
        }
        defer { sqlite3_close(db) }

        func loadWords() throws -> [WordStat] {
            let sql = "SELECT word, frequency, avgspeed, lastused FROM freqlog"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ImporterError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            var words: [WordStat] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                words.append(
                    WordStat(
                        word: String(cString: sqlite3_column_text(statement, 0)),
                        frequency: Int(sqlite3_column_int(statement, 1)),
                        avgMs: sqlite3_column_double(statement, 2) * 1_000,
                        lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                        source: "nexus"
                    )
                )
            }
            return words
        }

        func loadChords() throws -> [ChordStat] {
            let sql = "SELECT chord, frequency, lastused FROM chordlog"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ImporterError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            var chords: [ChordStat] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                chords.append(
                    ChordStat(
                        output: String(cString: sqlite3_column_text(statement, 0)),
                        frequency: Int(sqlite3_column_int(statement, 1)),
                        lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                        source: "nexus"
                    )
                )
            }
            return chords
        }

        return try ImportedStatsBundle(words: loadWords(), chords: loadChords())
    }
}

public struct FreechorderImporter {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public func load() throws -> [ChordEntry] {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ImporterError.missingFile(path)
        }

        let text = try String(contentsOf: path)
        let blocks = text.components(separatedBy: "\n- id: ").dropFirst()
        var chords: [ChordEntry] = []

        for block in blocks {
            guard let outputMatch = block.firstMatch(of: /(?m)^  output_text: (.+)$/) else {
                continue
            }
            let output = String(outputMatch.output.1)
            let keyMatches = block.matches(of: /(?m)^  - (.+)$/).map { String($0.output.1) }
            let inputKeys = keyMatches.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

            guard !inputKeys.isEmpty else { continue }

            chords.append(
                ChordEntry(
                    inputKeys: inputKeys,
                    output: output,
                    profile: .ansiQwerty,
                    deploymentTarget: .software,
                    source: "freechorder_review",
                    enabled: false
                )
            )
        }

        return chords
    }
}

public struct CharaChordImporter {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public func load(
        profile: ErgonomicProfile = .cc2A1,
        deploymentTarget: DeploymentTarget = .device,
        source: String? = nil,
        enabled: Bool = true
    ) throws -> [ChordEntry] {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ImporterError.missingFile(path)
        }

        let data = try Data(contentsOf: path)
        let file = try JSONDecoder().decode(CharaChordFile.self, from: data)
        guard file.charaVersion == 1, file.type == "chords" else {
            throw ImporterError.invalidFormat("Expected a charaVersion 1 chords file.")
        }

        let sourceName = source ?? path.lastPathComponent
        return file.chords.map { pair in
            let raw = RawChordRecord(inputActions: pair.input, phraseActions: pair.phrase)
            return ChordEntry(
                inputKeys: raw.display.inputTokens,
                output: raw.display.plainOutput ?? raw.display.displayOutput,
                rawInputActions: raw.inputActions,
                rawPhraseActions: raw.phraseActions,
                encodedInput: raw.encodedInput,
                encodedPhrase: raw.encodedPhrase,
                displayInput: raw.display.inputTokens,
                phraseTokens: raw.display.phraseTokens,
                actionFlags: raw.display.flags,
                plainOutput: raw.display.plainOutput,
                profile: profile,
                deploymentTarget: deploymentTarget,
                source: sourceName,
                enabled: enabled
            )
        }
    }
}

public enum CharaChordExporter {
    public static func file(from chords: [ChordEntry]) -> CharaChordFile {
        CharaChordFile(
            chords: chords.compactMap { chord in
                let rawRecord: RawChordRecord?
                if let record = chord.rawRecord {
                    rawRecord = record
                } else if let inputActions = ActionCodec.chordActions(forTokens: chord.inputKeys) {
                    rawRecord = RawChordRecord(
                        inputActions: inputActions,
                        phraseActions: ActionCodec.phraseActions(forPlainText: chord.output)
                    )
                } else {
                    rawRecord = nil
                }

                guard let rawRecord else { return nil }
                return CharaChordPair(input: rawRecord.inputActions, phrase: rawRecord.phraseActions)
            }
        )
    }
}
