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
    /// Autocomplete fragments and misspellings counted as this word.
    public let mergedWords: [String]
    /// When this word looks like the start of a longer word you finish with
    /// autocomplete (`zelv` for `zelvora`), that word.
    public let possibleCompletionOf: String?
    /// Every fragment that would merge into `possibleCompletionOf`.
    public let completionFragments: [String]

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
        candidates: [Candidate],
        mergedWords: [String] = [],
        possibleCompletionOf: String? = nil,
        completionFragments: [String] = []
    ) {
        self.mergedWords = mergedWords
        self.possibleCompletionOf = possibleCompletionOf
        self.completionFragments = completionFragments
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
    /// Words you merged into another word, keyed by the merged word.
    public let aliases: [String: String]

    public init(
        windowDays: Int,
        items: [GrowthItem],
        typos: [TypoFinding],
        uncoveredTimeShare: Double,
        uncoveredWordCount: Int,
        skippedWords: [String],
        arabicWordCount: Int,
        arabicOccurrences: Int,
        aliases: [String: String] = [:]
    ) {
        self.aliases = aliases
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
    /// Times the typed letters were finished with an autocomplete key.
    public let completedFrequency: Int
    /// Words folded into this one (autocomplete fragments, misspellings).
    public let mergedWords: [String]

    public var frequency: Int { typedFrequency + chordedFrequency }

    public init(
        word: String,
        language: WordLanguage,
        typedFrequency: Int,
        keyboardFrequency: Int,
        chordedFrequency: Int,
        typedAvgMs: Double,
        lastUsedAt: Date,
        completedFrequency: Int = 0,
        mergedWords: [String] = []
    ) {
        self.completedFrequency = completedFrequency
        self.mergedWords = mergedWords
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
        let completionTargets = Self.completionTargets(usage: usage, dictionary: dictionary)
        var fragmentsByTarget: [String: [String]] = [:]
        for (fragment, target) in completionTargets where (knownFrequency[fragment] ?? 0) >= Self.minimumFrequency {
            fragmentsByTarget[target, default: []].append(fragment)
        }
        // Misspellings of a word you have no chord for yet add to that word's
        // cost: its chord removes the typo too.
        var typoFolds: [String: (frequency: Int, time: Double, words: [String])] = [:]

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
            if let intended = Self.intendedWord(
                forTypo: entry.word,
                frequency: entry.typedFrequency,
                chordedWords: chordsByWord,
                knownFrequency: knownFrequency,
                dictionary: dictionary
            ) {
                if chordsByWord[intended] == nil {
                    var fold = typoFolds[intended] ?? (0, 0, [])
                    fold.frequency += entry.typedFrequency
                    fold.time += time
                    fold.words.append(entry.word)
                    typoFolds[intended] = fold
                } else {
                    typos.append(
                        TypoFinding(
                            typo: entry.word,
                            intended: intended,
                            frequency: entry.typedFrequency,
                            intendedChordInput: chordsByWord[intended]?.first.map(Self.displayInput)
                        )
                    )
                }
                continue
            }

            // After typo folding: half-typed words finished by shell or editor completion
            // (`scre` + Tab) are not words to chord.
            if !dictionary.contains(entry.word),
               entry.word.count <= 6,
               let relative = longerRelativeFrequency[entry.word],
               relative >= entry.typedFrequency {
                continue
            }
            if let base = chordedBase(for: entry.word, chordsByWord: chordsByWord) {
                pool.append((entry, .ending, base))
            } else {
                pool.append((entry, .word, nil))
            }
        }

        pool = pool.map { entry in
            guard let fold = typoFolds[entry.usage.word] else { return entry }
            return (Self.adding(fold, to: entry.usage), entry.category, entry.base)
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
            // Suggest merging into custom vocabulary (names, products), or
            // into any word once autocomplete has been seen finishing it.
            let suggestedCompletion = completionTargets[entry.usage.word].flatMap { target in
                !dictionary.contains(target) || entry.usage.completedFrequency > 0 ? target : nil
            }
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
                    candidates: candidates,
                    mergedWords: entry.usage.mergedWords,
                    possibleCompletionOf: suggestedCompletion,
                    completionFragments: suggestedCompletion
                        .flatMap { fragmentsByTarget[$0] }?
                        .sorted { (knownFrequency[$0] ?? 0) > (knownFrequency[$1] ?? 0) } ?? []
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

    // MARK: Folding fragments and misspellings

    /// For each non-dictionary word that is the start of a longer word you
    /// use, the word it most likely completes to. Chains resolve, so `zel`
    /// (start of `zelv`, itself the start of `zelvora`) maps to `zelvora`.
    public static func completionTargets(usage: [WordSourceUsage], dictionary: Set<String>) -> [String: String] {
        let frequency = Dictionary(usage.map { ($0.word, $0.frequency) }, uniquingKeysWith: +)
        var bestByPrefix: [String: (word: String, frequency: Int)] = [:]
        for (word, count) in frequency where count >= minimumFrequency && word.count >= 4 {
            let letters = Array(word)
            // At least two letters must be missing: one extra letter is a
            // plural or a misspelling (`topups`, `slopmetere`), not autocomplete.
            guard letters.count >= 5 else { continue }
            for length in 3...(letters.count - 2) {
                let prefix = String(letters.prefix(length))
                if let best = bestByPrefix[prefix],
                   best.frequency > count || (best.frequency == count && best.word < word) {
                    continue
                }
                bestByPrefix[prefix] = (word, count)
            }
        }

        var result: [String: String] = [:]
        for word in frequency.keys where word.count >= 3 && !dictionary.contains(word) {
            guard var target = bestByPrefix[word]?.word else { continue }
            var seen: Set<String> = [word, target]
            while !dictionary.contains(target),
                  let next = bestByPrefix[target]?.word,
                  seen.insert(next).inserted {
                target = next
            }
            result[word] = target
        }
        return result
    }

    /// Folds words into the word they stand for: explicit aliases you set,
    /// plus fragments you finished with an autocomplete key at least half the
    /// time. Counts, timing and chord use are combined.
    public static func fold(
        _ usage: [WordSourceUsage],
        aliases: [String: String],
        dictionary: Set<String>
    ) -> [WordSourceUsage] {
        var merges = aliases
        let targets = completionTargets(usage: usage, dictionary: dictionary)
        for entry in usage where merges[entry.word] == nil
            && entry.completedFrequency >= minimumFrequency
            && entry.completedFrequency * 2 >= entry.typedFrequency {
            if let target = targets[entry.word] {
                merges[entry.word] = target
            }
        }
        guard !merges.isEmpty else { return usage }

        func resolve(_ word: String) -> String {
            var current = word
            var seen: Set<String> = [word]
            while let next = merges[current], seen.insert(next).inserted {
                current = next
            }
            return current
        }

        struct Accumulator {
            var language: WordLanguage
            var typed = 0
            var keyboard = 0
            var chorded = 0
            var completed = 0
            var typedTime = 0.0
            var lastUsed = Date.distantPast
            var merged: [String] = []
            var hasOwnEntry = false
        }
        var byWord: [String: Accumulator] = [:]
        var order: [String] = []
        for entry in usage {
            let target = resolve(entry.word)
            if byWord[target] == nil {
                byWord[target] = Accumulator(language: entry.language)
                order.append(target)
            }
            var accumulator = byWord[target]!
            if entry.word == target {
                accumulator.language = entry.language
                accumulator.hasOwnEntry = true
            } else {
                accumulator.merged.append(entry.word)
            }
            accumulator.typed += entry.typedFrequency
            accumulator.keyboard += entry.keyboardFrequency
            accumulator.chorded += entry.chordedFrequency
            accumulator.completed += entry.completedFrequency
            accumulator.typedTime += entry.typedAvgMs * Double(entry.typedFrequency)
            accumulator.lastUsed = max(accumulator.lastUsed, entry.lastUsedAt)
            accumulator.merged.append(contentsOf: entry.mergedWords)
            byWord[target] = accumulator
        }

        return order.compactMap { word in
            guard let entry = byWord[word] else { return nil }
            return WordSourceUsage(
                word: word,
                language: entry.language,
                typedFrequency: entry.typed,
                keyboardFrequency: entry.keyboard,
                chordedFrequency: entry.chorded,
                typedAvgMs: entry.typed > 0 ? entry.typedTime / Double(entry.typed) : 0,
                lastUsedAt: entry.lastUsed,
                completedFrequency: entry.completed,
                mergedWords: entry.merged.sorted()
            )
        }
        .sorted { $0.frequency == $1.frequency ? $0.word < $1.word : $0.frequency > $1.frequency }
    }

    private static func adding(
        _ fold: (frequency: Int, time: Double, words: [String]),
        to usage: WordSourceUsage
    ) -> WordSourceUsage {
        let typed = usage.typedFrequency + fold.frequency
        let time = usage.typedAvgMs * Double(usage.typedFrequency) + fold.time
        return WordSourceUsage(
            word: usage.word,
            language: usage.language,
            typedFrequency: typed,
            keyboardFrequency: usage.keyboardFrequency + fold.frequency,
            chordedFrequency: usage.chordedFrequency,
            typedAvgMs: typed > 0 ? time / Double(typed) : usage.typedAvgMs,
            lastUsedAt: usage.lastUsedAt,
            completedFrequency: usage.completedFrequency,
            mergedWords: (usage.mergedWords + fold.words).sorted()
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
            return candidateFrequency >= max(frequency * 3, 10)
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
