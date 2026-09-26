import Foundation

/// Why a word is worth a chord, which decides how the chord is best shaped.
public enum GrowthCategory: String, Codable, Hashable, Sendable {
    /// An inflection of a word you already chord (`doing` from `do`). The
    /// family chord is the base chord plus one marker key, so there is nothing
    /// new to memorize, and CCOS suffix modifiers are an alternative.
    case ending
    /// A word with no chorded relative: names, product vocabulary, jargon.
    case word

    public var displayName: String {
        switch self {
        case .ending: return "Ending"
        case .word: return "Word"
        }
    }
}

public struct GrowthItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String { word }

    public let word: String
    public let frequency: Int
    public let avgMs: Double
    public let lastUsedAt: Date
    public let category: GrowthCategory
    /// The chorded word this one extends, for `.ending`.
    public let baseWord: String?
    public let baseChordInput: [String]?
    /// Best candidates first. The first candidate is conflict-free against the
    /// library and against the first candidates of every higher-ranked item,
    /// so accepting a whole batch never produces a collision.
    public let candidates: [Candidate]

    /// Milliseconds spent typing this word letter by letter in the window.
    public var timeCostMs: Double { Double(frequency) * min(avgMs, GrowthPlanner.avgMsCap) }

    public init(
        word: String,
        frequency: Int,
        avgMs: Double,
        lastUsedAt: Date,
        category: GrowthCategory,
        baseWord: String?,
        baseChordInput: [String]?,
        candidates: [Candidate]
    ) {
        self.word = word
        self.frequency = frequency
        self.avgMs = avgMs
        self.lastUsedAt = lastUsedAt
        self.category = category
        self.baseWord = baseWord
        self.baseChordInput = baseChordInput
        self.candidates = candidates
    }
}

public struct TypoFinding: Codable, Hashable, Sendable, Identifiable {
    public var id: String { typo }

    public let typo: String
    public let intended: String
    public let frequency: Int
    /// The chord that would have produced the intended word, if you have one.
    public let intendedChordInput: [String]?

    public init(typo: String, intended: String, frequency: Int, intendedChordInput: [String]?) {
        self.typo = typo
        self.intended = intended
        self.frequency = frequency
        self.intendedChordInput = intendedChordInput
    }
}

public struct GrowthPlan: Codable, Hashable, Sendable {
    public let windowDays: Int
    public let items: [GrowthItem]
    public let typos: [TypoFinding]
    /// Share of in-word typing time spent on words without a chord.
    public let uncoveredTimeShare: Double
    public let uncoveredWordCount: Int
    public let skippedWords: [String]
    public let arabicWordCount: Int
    public let arabicOccurrences: Int

    public init(
        windowDays: Int,
        items: [GrowthItem],
        typos: [TypoFinding],
        uncoveredTimeShare: Double,
        uncoveredWordCount: Int,
        skippedWords: [String],
        arabicWordCount: Int,
        arabicOccurrences: Int
    ) {
        self.windowDays = windowDays
        self.items = items
        self.typos = typos
        self.uncoveredTimeShare = uncoveredTimeShare
        self.uncoveredWordCount = uncoveredWordCount
        self.skippedWords = skippedWords
        self.arabicWordCount = arabicWordCount
        self.arabicOccurrences = arabicOccurrences
    }

    public static let empty = GrowthPlan(
        windowDays: 30,
        items: [],
        typos: [],
        uncoveredTimeShare: 0,
        uncoveredWordCount: 0,
        skippedWords: [],
        arabicWordCount: 0,
        arabicOccurrences: 0
    )
}

/// Word usage in a window, split by how the word was produced.
public struct WordSourceUsage: Hashable, Sendable {
    public let word: String
    public let language: WordLanguage
    public let typedFrequency: Int
    public let keyboardFrequency: Int
    public let chordedFrequency: Int
    /// Average milliseconds per letter-by-letter occurrence.
    public let typedAvgMs: Double
    public let lastUsedAt: Date

    public var frequency: Int { typedFrequency + chordedFrequency }

    public init(
        word: String,
        language: WordLanguage,
        typedFrequency: Int,
        keyboardFrequency: Int,
        chordedFrequency: Int,
        typedAvgMs: Double,
        lastUsedAt: Date
    ) {
        self.word = word
        self.language = language
        self.typedFrequency = typedFrequency
        self.keyboardFrequency = keyboardFrequency
        self.chordedFrequency = chordedFrequency
        self.typedAvgMs = typedAvgMs
        self.lastUsedAt = lastUsedAt
    }
}

/// Deterministic planning for which chords to add next. Pure, so it can be
/// tested without a database.
public struct GrowthPlanner: Sendable {
    /// Idle pauses inside a word are not typing time.
    static let avgMsCap: Double = 3_000
    /// Words typed fewer times than this in the window are noise.
    public static let minimumFrequency = 3
    /// Chord output arrives a few ms per character. A 3–4 letter token that
    /// was never typed slower than this is a leftover chord fragment.
    static let fragmentMaxAvgMs: Double = 90

    private let engine: SuggestionEngine
    private let morphology: EnglishMorphologyIndex

    public init(engine: SuggestionEngine = SuggestionEngine(), morphology: EnglishMorphologyIndex = .bundled) {
        self.engine = engine
        self.morphology = morphology
    }

    public func plan(
        usage: [WordSourceUsage],
        profile: ErgonomicProfile,
        existingChords: [ChordEntry],
        bannedInputs: Set<String>,
        skippedWords: Set<String>,
        dictionary: Set<String> = [],
        windowDays: Int,
        limit: Int
    ) -> GrowthPlan {
        let chordsByWord = Self.chordsByOutputWord(existingChords)
        let knownFrequency = Dictionary(
            usage.map { ($0.word, $0.frequency) },
            uniquingKeysWith: +
        )
        let longerRelativeFrequency = Self.longerRelativeFrequency(
            knownFrequency: knownFrequency,
            chordedWords: chordsByWord
        )

        var totalTime = 0.0
        var uncoveredTime = 0.0
        var uncoveredWords = 0
        var arabicWords = 0
        var arabicOccurrences = 0
        var typos: [TypoFinding] = []
        var pool: [(usage: WordSourceUsage, category: GrowthCategory, base: String?)] = []

        for entry in usage {
            let time = Double(entry.typedFrequency) * min(entry.typedAvgMs, Self.avgMsCap)
            totalTime += time
            guard chordsByWord[entry.word] == nil else { continue }
            uncoveredTime += time
            uncoveredWords += 1

            guard entry.typedFrequency >= Self.minimumFrequency else { continue }
            if entry.language == .arabic {
                arabicWords += 1
                arabicOccurrences += entry.typedFrequency
                continue
            }
            guard entry.language == .english,
                  entry.word.count >= 3,
                  !skippedWords.contains(entry.word) else { continue }
            if entry.word.count <= 4, entry.typedAvgMs < Self.fragmentMaxAvgMs {
                continue
            }
            // Half-typed words finished by shell or editor completion
            // (`scre` + Tab) are not words to chord.
            if !dictionary.contains(entry.word),
               entry.word.count <= 6,
               let relative = longerRelativeFrequency[entry.word],
               relative >= entry.typedFrequency {
                continue
            }
            if let intended = Self.intendedWord(
                forTypo: entry.word,
                frequency: entry.typedFrequency,
                chordedWords: chordsByWord,
                knownFrequency: knownFrequency,
                dictionary: dictionary
            ) {
                typos.append(
                    TypoFinding(
                        typo: entry.word,
                        intended: intended,
                        frequency: entry.typedFrequency,
                        intendedChordInput: chordsByWord[intended]?.first.map(Self.displayInput)
                    )
                )
                continue
            }

            if let base = chordedBase(for: entry.word, chordsByWord: chordsByWord) {
                pool.append((entry, .ending, base))
            } else {
                pool.append((entry, .word, nil))
            }
        }

        pool.sort { lhs, rhs in
            let lhsCost = Double(lhs.usage.typedFrequency) * min(lhs.usage.typedAvgMs, Self.avgMsCap)
            let rhsCost = Double(rhs.usage.typedFrequency) * min(rhs.usage.typedAvgMs, Self.avgMsCap)
            if lhsCost == rhsCost { return lhs.usage.word < rhs.usage.word }
            return lhsCost > rhsCost
        }

        // Plan sequentially: each accepted first candidate becomes part of the
        // library for the words after it, so the batch is conflict-free.
        var workingChords = existingChords
        var items: [GrowthItem] = []
        for entry in pool {
            guard items.count < limit else { break }
            let candidates = engine.adviseChord(
                for: entry.usage.word,
                profile: profile,
                existingChords: workingChords,
                bannedInputs: bannedInputs,
                limit: 3
            )
            guard let best = candidates.first else { continue }
            workingChords.append(
                ChordEntry(
                    inputKeys: best.inputKeys,
                    output: entry.usage.word,
                    profile: profile,
                    deploymentTarget: profile == .cc2A1 ? .device : .software,
                    source: "grow_plan"
                )
            )
            // Only call it an ending when the chord really is the base chord
            // plus a marker; otherwise there is no family to lean on.
            let extendsBase = best.softReasons.contains { $0.hasPrefix("Extends ") }
            let category: GrowthCategory = entry.category == .ending && extendsBase ? .ending : .word
            items.append(
                GrowthItem(
                    word: entry.usage.word,
                    frequency: entry.usage.typedFrequency,
                    avgMs: entry.usage.typedAvgMs,
                    lastUsedAt: entry.usage.lastUsedAt,
                    category: category,
                    baseWord: category == .ending ? entry.base : nil,
                    baseChordInput: category == .ending
                        ? entry.base.flatMap { chordsByWord[$0]?.first }.map(Self.displayInput)
                        : nil,
                    candidates: candidates
                )
            )
        }

        typos.sort { $0.frequency == $1.frequency ? $0.typo < $1.typo : $0.frequency > $1.frequency }
        return GrowthPlan(
            windowDays: windowDays,
            items: items,
            typos: typos,
            uncoveredTimeShare: totalTime > 0 ? uncoveredTime / totalTime : 0,
            uncoveredWordCount: uncoveredWords,
            skippedWords: skippedWords.sorted(),
            arabicWordCount: arabicWords,
            arabicOccurrences: arabicOccurrences
        )
    }

    /// The chorded lemma this word inflects, if any.
    func chordedBase(for word: String, chordsByWord: [String: [ChordEntry]]) -> String? {
        let inflections: Set<MorphologyRelation> = [.plural, .past, .gerund, .thirdPerson, .comparative, .superlative, .ly, .erOr]
        return morphology.matches(for: word)
            .first { inflections.contains($0.relation) && chordsByWord[$0.lemma] != nil }?
            .lemma
    }

    /// Returns the word you most likely meant when `word` is one edit away
    /// from a chorded or far more frequent word. Short words only count
    /// swapped letters (`hte`, `waht`); longer words also count one missing,
    /// extra or wrong letter (`reserach`, `fullfilled`).
    static func intendedWord(
        forTypo word: String,
        frequency: Int,
        chordedWords: [String: [ChordEntry]],
        knownFrequency: [String: Int],
        dictionary: Set<String> = []
    ) -> String? {
        // Real words (`fare`, `steam`) are never typos of their neighbors.
        guard !dictionary.contains(word) else { return nil }
        func isStrongTarget(_ candidate: String) -> Bool {
            guard candidate != word, !isInflection(candidate, of: word) else { return false }
            let candidateFrequency = knownFrequency[candidate] ?? 0
            if chordedWords[candidate] != nil {
                return candidateFrequency >= frequency * 2
            }
            return candidateFrequency >= max(frequency * 5, 10)
        }

        let letters = Array(word)
        var best: (word: String, frequency: Int)?
        func consider(_ candidate: String) {
            guard isStrongTarget(candidate) else { return }
            let candidateFrequency = knownFrequency[candidate] ?? 0
            if best == nil || candidateFrequency > best!.frequency {
                best = (candidate, candidateFrequency)
            }
        }

        for index in 0..<(letters.count - 1) where letters[index] != letters[index + 1] {
            var swapped = letters
            swapped.swapAt(index, index + 1)
            consider(String(swapped))
        }

        // An extra letter: any letter in long words, only a doubled one
        // (`aand`) in short words, where dropping a letter often lands on an
        // unrelated real word.
        if letters.count >= 4 {
            for index in letters.indices {
                let doubled = (index > 0 && letters[index - 1] == letters[index])
                    || (index + 1 < letters.count && letters[index + 1] == letters[index])
                guard letters.count >= 6 || doubled else { continue }
                var shorter = letters
                shorter.remove(at: index)
                consider(String(shorter))
            }
        }

        if letters.count >= 6 {
            let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
            for index in 0...letters.count {
                for letter in alphabet {
                    var longer = letters
                    longer.insert(letter, at: index)
                    consider(String(longer))
                }
            }
            for index in letters.indices {
                for letter in alphabet where letter != letters[index] {
                    var replaced = letters
                    replaced[index] = letter
                    consider(String(replaced))
                }
            }
            // Swapped letters one apart (`consice` for `concise`).
            for index in 0..<(letters.count - 2) where letters[index] != letters[index + 2] {
                var swapped = letters
                swapped.swapAt(index, index + 2)
                consider(String(swapped))
            }
        }

        return best?.word
    }

    /// `things`/`thing` or `used`/`use` differ by one letter but are both
    /// real words, not typos of each other.
    private static func isInflection(_ lhs: String, of rhs: String) -> Bool {
        let (short, long) = lhs.count < rhs.count ? (lhs, rhs) : (rhs, lhs)
        guard long.hasPrefix(short) else { return false }
        let suffix = String(long.dropFirst(short.count))
        return ["s", "es", "d", "ed", "ing", "ly", "er", "y"].contains(suffix)
    }

    /// For every 3–6 letter prefix or suffix of a known word, the highest
    /// frequency of a longer word that starts or ends with it.
    static func longerRelativeFrequency(
        knownFrequency: [String: Int],
        chordedWords: [String: [ChordEntry]]
    ) -> [String: Int] {
        var result: [String: Int] = [:]
        func add(_ word: String, frequency: Int) {
            let letters = Array(word)
            guard letters.count >= 4 else { return }
            for length in 3...min(6, letters.count - 1) {
                let prefix = String(letters.prefix(length))
                let suffix = String(letters.suffix(length))
                result[prefix] = max(result[prefix] ?? 0, frequency)
                result[suffix] = max(result[suffix] ?? 0, frequency)
            }
        }
        for (word, frequency) in knownFrequency {
            add(word, frequency: frequency)
        }
        for word in chordedWords.keys {
            // A chorded word counts as frequent: you use it enough to chord it.
            add(word, frequency: max(knownFrequency[word] ?? 0, Int.max / 2))
        }
        return result
    }

    /// Lowercased words from the system word lists, used to tell real words
    /// from typos and half-typed fragments. Empty when unavailable.
    public static func loadSystemDictionary() -> Set<String> {
        var words: Set<String> = []
        for path in ["/usr/share/dict/web2", "/usr/share/dict/propernames", "/usr/share/dict/web2a"] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let word = line.trimmingCharacters(in: .whitespaces).lowercased()
                if !word.isEmpty, !word.contains(" ") { words.insert(word) }
            }
        }
        return words
    }

    static func chordsByOutputWord(_ chords: [ChordEntry]) -> [String: [ChordEntry]] {
        var result: [String: [ChordEntry]] = [:]
        for chord in chords where chord.enabled {
            let output = chord.plainOutput ?? chord.output
            let words = MultilingualWordProcessor.words(in: output)
            guard words.count == 1, let word = words.first?.text else { continue }
            result[word, default: []].append(chord)
        }
        return result
    }

    static func displayInput(_ chord: ChordEntry) -> [String] {
        chord.displayInput.isEmpty ? chord.inputKeys : chord.displayInput
    }
}
