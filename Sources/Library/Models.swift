import Foundation

public enum ErgonomicProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case cc2A1 = "cc2_a1"
    case ansiQwerty = "ansi_qwerty"
    case ansiColemak = "ansi_colemak"
    case ansiColemakDH = "ansi_colemak_dh"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cc2A1:
            return "CC2 A1"
        case .ansiQwerty:
            return "ANSI QWERTY"
        case .ansiColemak:
            return "ANSI Colemak"
        case .ansiColemakDH:
            return "ANSI Colemak-DH"
        }
    }
}

public enum DeploymentTarget: String, Codable, CaseIterable, Sendable, Identifiable {
    case software
    case device
    case both

    public var id: String { rawValue }

    public var displayName: String {
        rawValue.capitalized
    }
}

public struct ChordEntry: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let inputKeys: [String]
    public let normalizedInput: String
    public let output: String
    public let rawInputActions: [Int]?
    public let rawPhraseActions: [Int]?
    public let encodedInput: String?
    public let encodedPhrase: String?
    public let displayInput: [String]
    public let phraseTokens: [String]
    public let actionFlags: Set<ChordFlag>
    public let plainOutput: String?
    public let profile: ErgonomicProfile
    public let deploymentTarget: DeploymentTarget
    public let source: String
    public let enabled: Bool
    public let isStarred: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        inputKeys: [String],
        normalizedInput: String? = nil,
        output: String,
        rawInputActions: [Int]? = nil,
        rawPhraseActions: [Int]? = nil,
        encodedInput: String? = nil,
        encodedPhrase: String? = nil,
        displayInput: [String]? = nil,
        phraseTokens: [String]? = nil,
        actionFlags: Set<ChordFlag> = [],
        plainOutput: String? = nil,
        profile: ErgonomicProfile,
        deploymentTarget: DeploymentTarget,
        source: String,
        enabled: Bool = true,
        isStarred: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.inputKeys = inputKeys
        self.normalizedInput = normalizedInput ?? Self.normalizeInputKeys(inputKeys)
        self.output = output
        self.rawInputActions = rawInputActions
        self.rawPhraseActions = rawPhraseActions
        self.encodedInput = encodedInput
        self.encodedPhrase = encodedPhrase
        self.displayInput = displayInput ?? inputKeys
        self.phraseTokens = phraseTokens ?? output.map { String($0) }
        self.actionFlags = actionFlags
        self.plainOutput = plainOutput ?? output
        self.profile = profile
        self.deploymentTarget = deploymentTarget
        self.source = source
        self.enabled = enabled
        self.isStarred = isStarred
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func normalizeInputKeys(_ inputKeys: [String]) -> String {
        inputKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "+")
    }

    public var rawRecord: RawChordRecord? {
        if let rawInputActions, let rawPhraseActions {
            return RawChordRecord(inputActions: rawInputActions, phraseActions: rawPhraseActions)
        }
        if let encodedInput, let encodedPhrase {
            return RawChordRecord(encodedInput: encodedInput, encodedPhrase: encodedPhrase)
        }
        return nil
    }

    public var searchText: String {
        (
            inputKeys
            + displayInput
            + phraseTokens
            + actionFlags.map(\.rawValue)
            + [normalizedInput, output, plainOutput ?? "", source, profile.rawValue, deploymentTarget.rawValue]
        )
        .joined(separator: " ")
        .lowercased()
    }

    public func withStarred(_ isStarred: Bool) -> ChordEntry {
        ChordEntry(
            id: id,
            inputKeys: inputKeys,
            normalizedInput: normalizedInput,
            output: output,
            rawInputActions: rawInputActions,
            rawPhraseActions: rawPhraseActions,
            encodedInput: encodedInput,
            encodedPhrase: encodedPhrase,
            displayInput: displayInput,
            phraseTokens: phraseTokens,
            actionFlags: actionFlags,
            plainOutput: plainOutput,
            profile: profile,
            deploymentTarget: deploymentTarget,
            source: source,
            enabled: enabled,
            isStarred: isStarred,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public struct ChordFeedback: Codable, Hashable, Sendable, Identifiable {
    public let chordId: UUID
    public let starred: Bool
    public let source: String
    public let createdAt: Date
    public let updatedAt: Date

    public var id: UUID { chordId }

    public init(
        chordId: UUID,
        starred: Bool,
        source: String = "user",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.chordId = chordId
        self.starred = starred
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct WordStat: Codable, Hashable, Sendable {
    public let word: String
    public let frequency: Int
    public let avgMs: Double
    public let lastUsedAt: Date
    public let source: String
    public let language: WordLanguage

    public init(
        word: String,
        frequency: Int,
        avgMs: Double,
        lastUsedAt: Date,
        source: String,
        language: WordLanguage = .other
    ) {
        self.word = word
        self.frequency = frequency
        self.avgMs = avgMs
        self.lastUsedAt = lastUsedAt
        self.source = source
        self.language = language
    }
}

public struct ChordStat: Codable, Hashable, Sendable {
    public let output: String
    public let frequency: Int
    public let lastUsedAt: Date
    public let source: String

    public init(output: String, frequency: Int, lastUsedAt: Date, source: String) {
        self.output = output
        self.frequency = frequency
        self.lastUsedAt = lastUsedAt
        self.source = source
    }
}

public enum UsageSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case keyboard
    /// Typed on another keyboard while no Master Forge was connected, so no
    /// chord was possible. Counts as typing, never as a missed chord.
    case keyboardAway = "keyboard_away"
    case m4gTyping = "m4g_typing"
    case m4gHIDConfirmed = "m4g_hid_confirmed"
    case softwareChord = "software_chord"
    /// Replaced from a laptop shorthand (a chord's letters typed, then Space).
    case laptopShorthand = "laptop_shorthand"
    case nexusImport = "nexus_import"

    public var id: String { rawValue }

    /// Sources where the word was produced letter by letter.
    public static let typedSources: [UsageSource] = [.keyboard, .m4gTyping]
    /// Sources where the word came out of a chord.
    public static let chordedSources: [UsageSource] = [.m4gHIDConfirmed, .softwareChord]

    public var displayName: String {
        switch self {
        case .keyboard:
            return "Keyboard"
        case .keyboardAway:
            return "Keyboard, M4G not connected"
        case .m4gTyping:
            return "M4G typing"
        case .m4gHIDConfirmed:
            return "M4G confirmed"
        case .softwareChord:
            return "Software chord"
        case .laptopShorthand:
            return "Laptop shorthand"
        case .nexusImport:
            return "Nexus import"
        }
    }
}

/// How a word was produced, for words-per-minute.
public enum SpeedMethod: String, Codable, CaseIterable, Sendable {
    case keyboard
    case m4gLetters = "m4g_letters"
    case m4gChords = "m4g_chords"
}

public enum MisfireKind: String, Codable, CaseIterable, Sendable {
    /// A chord's output deleted straight away.
    case deleted
    /// Letters at chord speed that match no chord and no word.
    case garbled
}

public enum ChordUsageConfidence: String, Codable, CaseIterable, Sendable, Identifiable {
    case exactSoftware = "exact_software"
    case confirmedHardware = "confirmed_hardware"
    case ambiguousOutput = "ambiguous_output"
    /// A chord-speed M4G burst with no exact library output, such as a chord
    /// finished with a CCOS suffix modifier ("go" + -ing -> "going").
    case chordBurst = "chord_burst"
    case nexusImport = "nexus_import"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .exactSoftware:
            return "Exact software"
        case .confirmedHardware:
            return "Confirmed hardware"
        case .ambiguousOutput:
            return "Ambiguous output"
        case .chordBurst:
            return "Chord burst"
        case .nexusImport:
            return "Nexus import"
        }
    }
}

public struct DailyWordUsage: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(day):\(source.rawValue):\(word)" }

    public let day: String
    public let word: String
    public let source: UsageSource
    public let frequency: Int
    public let avgMs: Double
    public let lastUsedAt: Date
    public let language: WordLanguage

    public init(
        day: String,
        word: String,
        source: UsageSource,
        frequency: Int,
        avgMs: Double,
        lastUsedAt: Date,
        language: WordLanguage = .other
    ) {
        self.day = day
        self.word = word
        self.source = source
        self.frequency = frequency
        self.avgMs = avgMs
        self.lastUsedAt = lastUsedAt
        self.language = language
    }
}

public struct WordCoverageStat: Codable, Hashable, Sendable, Identifiable {
    public var id: String { word }

    public let word: String
    public let language: WordLanguage
    public let frequency: Int
    public let avgMs: Double
    public let lastUsedAt: Date
    public let matchingChords: [ChordEntry]

    public var isCovered: Bool { !matchingChords.isEmpty }

    public init(
        word: String,
        language: WordLanguage,
        frequency: Int,
        avgMs: Double,
        lastUsedAt: Date,
        matchingChords: [ChordEntry]
    ) {
        self.word = word
        self.language = language
        self.frequency = frequency
        self.avgMs = avgMs
        self.lastUsedAt = lastUsedAt
        self.matchingChords = matchingChords
    }
}

public struct WordCoverageReport: Codable, Hashable, Sendable {
    public let totalOccurrences: Int
    public let coveredOccurrences: Int
    public let uniqueWords: Int
    public let coveredUniqueWords: Int
    public let coveredWords: [WordCoverageStat]
    public let uncoveredWords: [WordCoverageStat]

    public var uncoveredOccurrences: Int { max(0, totalOccurrences - coveredOccurrences) }
    public var uncoveredUniqueWords: Int { max(0, uniqueWords - coveredUniqueWords) }
    public var coverageRate: Double {
        guard totalOccurrences > 0 else { return 0 }
        return Double(coveredOccurrences) / Double(totalOccurrences)
    }

    public init(
        totalOccurrences: Int,
        coveredOccurrences: Int,
        uniqueWords: Int,
        coveredUniqueWords: Int,
        coveredWords: [WordCoverageStat],
        uncoveredWords: [WordCoverageStat]
    ) {
        self.totalOccurrences = totalOccurrences
        self.coveredOccurrences = coveredOccurrences
        self.uniqueWords = uniqueWords
        self.coveredUniqueWords = coveredUniqueWords
        self.coveredWords = coveredWords
        self.uncoveredWords = uncoveredWords
    }

    public static let empty = WordCoverageReport(
        totalOccurrences: 0,
        coveredOccurrences: 0,
        uniqueWords: 0,
        coveredUniqueWords: 0,
        coveredWords: [],
        uncoveredWords: []
    )
}

public struct DailyChordUsage: Codable, Hashable, Sendable, Identifiable {
    public var id: String {
        "\(day):\(source.rawValue):\(matchedChordId?.uuidString ?? "none"):\(output)"
    }

    public let day: String
    public let output: String
    public let matchedChordId: UUID?
    public let source: UsageSource
    public let frequency: Int
    public let avgMs: Double
    public let confidence: ChordUsageConfidence
    public let ambiguityCount: Int
    public let lastUsedAt: Date

    public init(
        day: String,
        output: String,
        matchedChordId: UUID?,
        source: UsageSource,
        frequency: Int,
        avgMs: Double,
        confidence: ChordUsageConfidence,
        ambiguityCount: Int,
        lastUsedAt: Date
    ) {
        self.day = day
        self.output = output
        self.matchedChordId = matchedChordId
        self.source = source
        self.frequency = frequency
        self.avgMs = avgMs
        self.confidence = confidence
        self.ambiguityCount = ambiguityCount
        self.lastUsedAt = lastUsedAt
    }
}

public struct UsageOverview: Codable, Hashable, Sendable {
    public let wordsToday: Int
    public let chordsToday: Int
    public let words7Days: Int
    public let chords7Days: Int
    public let words30Days: Int
    public let chords30Days: Int
    public let wordsAllTime: Int
    public let chordsAllTime: Int

    public init(
        wordsToday: Int,
        chordsToday: Int,
        words7Days: Int,
        chords7Days: Int,
        words30Days: Int,
        chords30Days: Int,
        wordsAllTime: Int,
        chordsAllTime: Int
    ) {
        self.wordsToday = wordsToday
        self.chordsToday = chordsToday
        self.words7Days = words7Days
        self.chords7Days = chords7Days
        self.words30Days = words30Days
        self.chords30Days = chords30Days
        self.wordsAllTime = wordsAllTime
        self.chordsAllTime = chordsAllTime
    }
}

public struct TwoKeyChordImpact: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { chord.id }

    public let chord: ChordEntry
    public let totalFrequency: Int
    public let frequency7Days: Int
    public let frequency30Days: Int
    public let lastUsedAt: Date?
    public let confidence: ChordUsageConfidence?
    public let ambiguityCount: Int

    public init(
        chord: ChordEntry,
        totalFrequency: Int,
        frequency7Days: Int,
        frequency30Days: Int,
        lastUsedAt: Date?,
        confidence: ChordUsageConfidence?,
        ambiguityCount: Int
    ) {
        self.chord = chord
        self.totalFrequency = totalFrequency
        self.frequency7Days = frequency7Days
        self.frequency30Days = frequency30Days
        self.lastUsedAt = lastUsedAt
        self.confidence = confidence
        self.ambiguityCount = ambiguityCount
    }
}

public struct Candidate: Codable, Hashable, Sendable, Identifiable {
    public var id: String { inputKeys.joined(separator: "+") }

    public let inputKeys: [String]
    public let score: Double
    public let hardFailures: [String]
    public let softReasons: [String]

    public init(inputKeys: [String], score: Double, hardFailures: [String], softReasons: [String]) {
        self.inputKeys = inputKeys
        self.score = score
        self.hardFailures = hardFailures
        self.softReasons = softReasons
    }
}

public struct Suggestion: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(profile.rawValue):\(word.lowercased())" }

    public let word: String
    public let profile: ErgonomicProfile
    public let candidates: [Candidate]
    public let priorityScore: Double
    public let acceptedChordId: UUID?
    public let bannedAt: Date?

    public init(
        word: String,
        profile: ErgonomicProfile,
        candidates: [Candidate],
        priorityScore: Double,
        acceptedChordId: UUID? = nil,
        bannedAt: Date? = nil
    ) {
        self.word = word
        self.profile = profile
        self.candidates = candidates
        self.priorityScore = priorityScore
        self.acceptedChordId = acceptedChordId
        self.bannedAt = bannedAt
    }
}

public struct DeviceSource: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let portPath: String
    public let deviceName: String
    public let firmware: String
    public let chordCount: Int
    public let isPrimary: Bool

    public init(
        id: UUID = UUID(),
        portPath: String,
        deviceName: String,
        firmware: String,
        chordCount: Int,
        isPrimary: Bool
    ) {
        self.id = id
        self.portPath = portPath
        self.deviceName = deviceName
        self.firmware = firmware
        self.chordCount = chordCount
        self.isPrimary = isPrimary
    }
}

public struct DeviceChordRecord: Codable, Hashable, Sendable {
    public let inputKeys: [String]
    public let output: String
    public let rawInput: String?
    public let rawOutput: String?
    public let rawInputActions: [Int]?
    public let rawPhraseActions: [Int]?

    public init(
        inputKeys: [String],
        output: String,
        rawInput: String? = nil,
        rawOutput: String? = nil,
        rawInputActions: [Int]? = nil,
        rawPhraseActions: [Int]? = nil
    ) {
        self.inputKeys = inputKeys
        self.output = output
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.rawInputActions = rawInputActions
        self.rawPhraseActions = rawPhraseActions
    }

    public init(chord: ChordEntry) {
        let inputActions = chord.rawInputActions ?? chord.encodedInput.map(ActionCodec.parseChordActions)
        let phraseActions = chord.rawPhraseActions ?? chord.encodedPhrase.map(ActionCodec.parsePhraseActions)
        let encodedInput = chord.encodedInput ?? inputActions.map(ActionCodec.stringifyChordActions)
        let encodedPhrase = chord.encodedPhrase ?? phraseActions.map(ActionCodec.stringifyPhraseActions)

        self.init(
            inputKeys: chord.inputKeys,
            output: chord.plainOutput ?? chord.output,
            rawInput: encodedInput,
            rawOutput: encodedPhrase,
            rawInputActions: inputActions,
            rawPhraseActions: phraseActions
        )
    }
}

public enum BanKind: String, Codable, Sendable {
    case word
    case chord
}

public enum LibraryError: LocalizedError {
    case invalidChordInput
    case missingPrimaryDevice
    case sqliteError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidChordInput:
            return "Chord input cannot be empty."
        case .missingPrimaryDevice:
            return "A primary device snapshot is required for bootstrap."
        case .sqliteError(let message):
            return message
        }
    }
}

public enum AppSupportPaths {
    public static var baseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Chordsmith", isDirectory: true)
    }

    public static var databaseURL: URL {
        baseURL.appendingPathComponent("chordsmith.sqlite3")
    }
}
