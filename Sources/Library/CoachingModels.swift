import Foundation

// MARK: - Phrases

/// A two- or three-word phrase and how often it was written in a window.
public struct PhraseUsage: Codable, Hashable, Sendable, Identifiable {
    public var id: String { phrase }

    public let phrase: String
    public let wordCount: Int
    public let frequency: Int
    /// Times every word of the phrase was typed letter by letter.
    public let handFrequency: Int

    public init(phrase: String, wordCount: Int, frequency: Int, handFrequency: Int) {
        self.phrase = phrase
        self.wordCount = wordCount
        self.frequency = frequency
        self.handFrequency = handFrequency
    }

    public var words: [String] { phrase.split(separator: " ").map(String.init) }
}

public struct PhraseItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String { phrase }

    public let phrase: String
    public let wordCount: Int
    public let frequency: Int
    public let handFrequency: Int
    /// Estimated milliseconds spent writing this phrase in the window.
    public let estimatedMs: Double
    /// Conflict-free inputs, best first. Phrase chords lean on the first
    /// letters of each word plus the space key, so they read as "a phrase".
    public let candidates: [Candidate]

    public init(phrase: String, wordCount: Int, frequency: Int, handFrequency: Int, estimatedMs: Double, candidates: [Candidate]) {
        self.phrase = phrase
        self.wordCount = wordCount
        self.frequency = frequency
        self.handFrequency = handFrequency
        self.estimatedMs = estimatedMs
        self.candidates = candidates
    }
}

extension GrowthPlanner {
    /// Rough cost of producing a chorded word: press, release, next chord.
    static let chordActionMs: Double = 350

    /// Ranks phrases by the time they take today and gives each a
    /// conflict-free phrase chord. Every first candidate is also free of the
    /// first candidates ranked above it, so a batch commits cleanly.
    public func planPhrases(
        phrases: [PhraseUsage],
        wordAvgMs: [String: Double],
        existingChords: [ChordEntry],
        bannedInputs: Set<String>,
        dictionary: Set<String> = [],
        minimumFrequency: Int = 4,
        limit: Int = 40
    ) -> [PhraseItem] {
        let existingOutputs = Set(existingChords.map { ($0.plainOutput ?? $0.output).lowercased() })
        func isEligible(_ usage: PhraseUsage) -> Bool {
            guard usage.frequency >= minimumFrequency, !existingOutputs.contains(usage.phrase) else { return false }
            for word in usage.words {
                guard MultilingualWordProcessor.language(of: word) == .english else { return false }
                let known = dictionary.isEmpty || dictionary.contains(word) || wordAvgMs[word] != nil
                guard known else { return false }
            }
            return true
        }
        var ranked: [(PhraseUsage, Double)] = []
        for usage in phrases where isEligible(usage) {
            ranked.append((usage, Self.phraseCost(usage, wordAvgMs: wordAvgMs)))
        }
        ranked.sort { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.phrase < rhs.0.phrase : lhs.1 > rhs.1
        }

        var workingChords = existingChords
        var items: [PhraseItem] = []
        for (usage, cost) in ranked {
            guard items.count < limit else { break }
            let candidates = phraseCandidates(for: usage.words, existingChords: workingChords, bannedInputs: bannedInputs)
            guard let best = candidates.first else { continue }
            workingChords.append(
                ChordEntry(
                    inputKeys: best.inputKeys,
                    output: usage.phrase,
                    profile: .cc2A1,
                    deploymentTarget: .device,
                    source: "grow_plan"
                )
            )
            items.append(
                PhraseItem(
                    phrase: usage.phrase,
                    wordCount: usage.wordCount,
                    frequency: usage.frequency,
                    handFrequency: usage.handFrequency,
                    estimatedMs: cost,
                    candidates: candidates
                )
            )
        }
        return items
    }

    static func phraseCost(_ usage: PhraseUsage, wordAvgMs: [String: Double]) -> Double {
        var handMs = 0.0
        for word in usage.words {
            handMs += wordAvgMs[word] ?? 400
        }
        let chordedMs = Double(usage.wordCount) * chordActionMs
        let handCost = Double(usage.handFrequency) * handMs
        let chordedCost = Double(usage.frequency - usage.handFrequency) * chordedMs
        return handCost + chordedCost
    }

    func phraseCandidates(for words: [String], existingChords: [ChordEntry], bannedInputs: Set<String>) -> [Candidate] {
        let letters = words.map { Array($0) }
        let initials = orderedUnique(letters.compactMap { $0.first.map(String.init) })
        var proposals: [([String], String)] = []
        if initials.count >= 2 {
            proposals.append((initials + ["space"], "First letters of each word plus space."))
        }
        // A second letter from one word, for when the initials are taken.
        for (index, word) in letters.enumerated() where word.count >= 2 {
            let extra = String(word[1])
            let tokens = orderedUnique(initials + [extra])
            guard tokens.count > initials.count else { continue }
            proposals.append((tokens + ["space"], "First letters plus `\(extra)` from \(words[index]), plus space."))
        }
        if initials.count >= 2 {
            proposals.append((initials, "First letters of each word."))
        }
        for (index, word) in letters.enumerated() where word.count >= 3 {
            let extra = String(word[word.count - 1])
            let tokens = orderedUnique(initials + [extra])
            guard tokens.count > initials.count else { continue }
            proposals.append((tokens + ["space"], "First letters plus the last letter of \(words[index]), plus space."))
        }

        var seen: Set<String> = []
        var candidates: [Candidate] = []
        for (index, proposal) in proposals.enumerated() {
            let key = ChordEntry.normalizeInputKeys(proposal.0)
            guard seen.insert(key).inserted, !bannedInputs.contains(key) else { continue }
            let validation = ChordInputValidator.validateM4GDeviceTokens(proposal.0, existingChords: existingChords)
            guard validation.isValid else { continue }
            candidates.append(
                Candidate(
                    inputKeys: validation.tokens,
                    score: 100 - Double(index),
                    hardFailures: [],
                    softReasons: [proposal.1]
                )
            )
            if candidates.count == 3 { break }
        }
        if candidates.isEmpty {
            // Every first-letter shape is taken: fall back to the advisor's
            // usual search over the phrase's letters.
            let fallback = engine.adviseChord(
                for: words.joined(),
                profile: .cc2A1,
                existingChords: existingChords,
                bannedInputs: bannedInputs,
                allowReplacingOutput: true,
                limit: 3
            )
            candidates = fallback.map { candidate in
                Candidate(
                    inputKeys: candidate.inputKeys,
                    score: candidate.score,
                    hardFailures: [],
                    softReasons: ["First-letter chords are taken; picked from the phrase's letters."]
                )
            }
        }
        return candidates
    }

    private func orderedUnique(_ tokens: [String]) -> [String] {
        var seen: Set<String> = []
        return tokens.filter { seen.insert($0).inserted }
    }
}

// MARK: - Live coaching

/// Everything the live coach needs to recognise a moment worth a nudge.
public struct CoachingSnapshot: Sendable {
    /// Words with a device chord, and that chord's keys.
    public let chordInputs: [String: [String]]
    /// Misspellings of chorded words, mapped to the intended word.
    public let typoTargets: [String: String]
    /// Your most-used words that have a chord: the daily goal set.
    public let goalWords: Set<String>

    public init(chordInputs: [String: [String]], typoTargets: [String: String], goalWords: Set<String>) {
        self.chordInputs = chordInputs
        self.typoTargets = typoTargets
        self.goalWords = goalWords
    }

    public static let empty = CoachingSnapshot(chordInputs: [:], typoTargets: [:], goalWords: [])
}

/// Today's usage so far, for the menu bar and the nudge counters.
public struct TodayUsage: Sendable {
    /// The day these totals belong to; a new day starts from zero.
    public let day: Date
    public var chordedWords = 0
    public var handTypedWords = 0
    /// Typed with no Master Forge connected; left out of the chord rate.
    public var awayWords = 0
    /// Replaced from laptop shorthands.
    public var shorthandWords = 0
    public var goalChorded = 0
    public var goalTotal = 0
    public var m4gLetters = 0
    public var m4gMs = 0.0
    public var keyboardLetters = 0
    public var keyboardMs = 0.0
    /// Letter-by-letter count per word today.
    public var handCounts: [String: Int] = [:]
    /// Words-per-minute samples for today, per input method.
    public var speed = StatsBucket(start: .distantPast)

    public init(day: Date = .now) {
        self.day = day
    }

    public var words: Int { chordedWords + handTypedWords }
    public var chordRate: Double? { words > 0 ? Double(chordedWords) / Double(words) : nil }
    public var goalRate: Double? { goalTotal > 0 ? Double(goalChorded) / Double(goalTotal) : nil }
    public var m4gWPM: Double? { StatsBucket.wpm(letters: m4gLetters, ms: m4gMs) }
    public var keyboardWPM: Double? { StatsBucket.wpm(letters: keyboardLetters, ms: keyboardMs) }

    /// Adds one recorded word.
    public mutating func record(word: String, source: UsageSource, avgMs: Double, isGoalWord: Bool, cycleMs: Double? = nil) {
        let letters = word.count
        let ms = min(avgMs, 3_000)
        if let cycleMs {
            switch source {
            case .m4gHIDConfirmed:
                speed.chordSpeedChars += letters + 1
                speed.chordSpeedMs += cycleMs
            case .m4gTyping:
                speed.m4gLetterSpeedChars += letters + 1
                speed.m4gLetterSpeedMs += cycleMs
            case .keyboard, .keyboardAway, .laptopShorthand:
                speed.keyboardSpeedChars += letters + 1
                speed.keyboardSpeedMs += cycleMs
            case .softwareChord, .nexusImport:
                break
            }
        }
        switch source {
        case .m4gHIDConfirmed, .softwareChord:
            chordedWords += 1
            if isGoalWord { goalChorded += 1 }
        case .m4gTyping:
            handTypedWords += 1
            m4gLetters += letters
            m4gMs += ms
            handCounts[word, default: 0] += 1
        case .keyboard:
            handTypedWords += 1
            keyboardLetters += letters
            keyboardMs += ms
            handCounts[word, default: 0] += 1
        case .keyboardAway:
            awayWords += 1
            keyboardLetters += letters
            keyboardMs += ms
            return
        case .laptopShorthand:
            shorthandWords += 1
            return
        case .nexusImport:
            return
        }
        if isGoalWord { goalTotal += 1 }
    }
}

// MARK: - Speed drills

public struct BigramTiming: Codable, Hashable, Sendable, Identifiable {
    public var id: String { bigram }
    public let bigram: String
    public let averageMs: Double
    public let count: Int

    public init(bigram: String, averageMs: Double, count: Int) {
        self.bigram = bigram
        self.averageMs = averageMs
        self.count = count
    }
}

public struct SpeedDrillResult: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let finishedAt: Date
    public let wpm: Double
    public let accuracy: Double
    public let characters: Int
    public let slowBigrams: [BigramTiming]

    public init(id: UUID = UUID(), finishedAt: Date = .now, wpm: Double, accuracy: Double, characters: Int, slowBigrams: [BigramTiming]) {
        self.id = id
        self.finishedAt = finishedAt
        self.wpm = wpm
        self.accuracy = accuracy
        self.characters = characters
        self.slowBigrams = slowBigrams
    }
}

public enum SpeedDrillBuilder {
    /// Picks drill words: most of them contain your slowest letter pairs, the
    /// rest are words you type by hand most often, so practice transfers.
    public static func words(
        pool: [String],
        slowBigrams: [String],
        count: Int = 14,
        seed: UInt64 = UInt64(Date().timeIntervalSince1970)
    ) -> [String] {
        var generator = SeededGenerator(seed: seed)
        let targeted = pool.filter { word in slowBigrams.prefix(4).contains { word.contains($0) } }
        let targetedCount = targeted.isEmpty ? 0 : min(targeted.count, count * 3 / 5)
        var chosen = Array(targeted.shuffled(using: &generator).prefix(targetedCount))
        let rest = pool.prefix(80).filter { !chosen.contains($0) }.shuffled(using: &generator)
        chosen.append(contentsOf: rest.prefix(count - chosen.count))
        return chosen.shuffled(using: &generator)
    }

    /// Per-letter-pair timing from the characters of a drill, as typed.
    public static func bigramTimings(typed: [(character: Character, time: Date)]) -> [String: (totalMs: Double, count: Int)] {
        var result: [String: (Double, Int)] = [:]
        for (previous, next) in zip(typed, typed.dropFirst()) {
            guard previous.character.isLetter, next.character.isLetter else { continue }
            let ms = next.time.timeIntervalSince(previous.time) * 1_000
            // Pauses to read the next word are not finger speed.
            guard ms > 0, ms < 1_500 else { continue }
            let bigram = String([previous.character, next.character]).lowercased()
            let current = result[bigram] ?? (0, 0)
            result[bigram] = (current.0 + ms, current.1 + 1)
        }
        return result.mapValues { (totalMs: $0.0, count: $0.1) }
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
