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

    public init(word: String, frequency: Int, avgMs: Double, lastUsedAt: Date, source: String) {
        self.word = word
        self.frequency = frequency
        self.avgMs = avgMs
        self.lastUsedAt = lastUsedAt
        self.source = source
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
            .appendingPathComponent("Charaworder", isDirectory: true)
    }

    public static var databaseURL: URL {
        baseURL.appendingPathComponent("charaworder.sqlite3")
    }
}
