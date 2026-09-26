import Foundation

/// A word you have a chord for but still typed letter by letter.
public struct ForgottenChord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { word }

    public let word: String
    public let chordInputs: [[String]]
    public let typedFrequency: Int
    /// Typed on a keyboard other than the Master Forge.
    public let keyboardFrequency: Int
    public let chordedFrequency: Int
    public let typedAvgMs: Double

    public var m4gTypedFrequency: Int { max(0, typedFrequency - keyboardFrequency) }
    /// Share of this word's uses that came out of a chord.
    public var chordRate: Double {
        let total = typedFrequency + chordedFrequency
        return total > 0 ? Double(chordedFrequency) / Double(total) : 0
    }

    public init(
        word: String,
        chordInputs: [[String]],
        typedFrequency: Int,
        keyboardFrequency: Int,
        chordedFrequency: Int,
        typedAvgMs: Double
    ) {
        self.word = word
        self.chordInputs = chordInputs
        self.typedFrequency = typedFrequency
        self.keyboardFrequency = keyboardFrequency
        self.chordedFrequency = chordedFrequency
        self.typedAvgMs = typedAvgMs
    }
}

/// A chord you added recently, with whether you have started using it.
public struct LearningChord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { chord.id }

    public let chord: ChordEntry
    public let chordedSinceAdded: Int
    public let typedSinceAdded: Int

    public var word: String { chord.plainOutput ?? chord.output }
    public var input: [String] { chord.displayInput.isEmpty ? chord.inputKeys : chord.displayInput }

    public init(chord: ChordEntry, chordedSinceAdded: Int, typedSinceAdded: Int) {
        self.chord = chord
        self.chordedSinceAdded = chordedSinceAdded
        self.typedSinceAdded = typedSinceAdded
    }
}

public struct PracticeReport: Codable, Hashable, Sendable {
    public let windowDays: Int
    public let forgotten: [ForgottenChord]
    public let typos: [TypoFinding]
    public let learning: [LearningChord]
    public let learnedCount: Int
    /// Words in the window by how they were produced.
    public let keyboardWords: Int
    public let m4gTypedWords: Int
    public let chordedWords: Int

    public var totalWords: Int { keyboardWords + m4gTypedWords + chordedWords }
    /// True when the recorder has not credited a single word to the Master
    /// Forge, which means physical attribution is not working.
    public var lacksM4GAttribution: Bool { totalWords > 0 && m4gTypedWords + chordedWords == 0 }

    public init(
        windowDays: Int,
        forgotten: [ForgottenChord],
        typos: [TypoFinding],
        learning: [LearningChord],
        learnedCount: Int,
        keyboardWords: Int,
        m4gTypedWords: Int,
        chordedWords: Int
    ) {
        self.windowDays = windowDays
        self.forgotten = forgotten
        self.typos = typos
        self.learning = learning
        self.learnedCount = learnedCount
        self.keyboardWords = keyboardWords
        self.m4gTypedWords = m4gTypedWords
        self.chordedWords = chordedWords
    }

    public static let empty = PracticeReport(
        windowDays: 7,
        forgotten: [],
        typos: [],
        learning: [],
        learnedCount: 0,
        keyboardWords: 0,
        m4gTypedWords: 0,
        chordedWords: 0
    )
}
