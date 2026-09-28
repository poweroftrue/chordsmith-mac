import Foundation

public struct GeneratedSuggestionSet: Sendable {
    public let suggestions: [Suggestion]

    public init(suggestions: [Suggestion]) {
        self.suggestions = suggestions
    }
}

private enum Hand: String {
    case left
    case right
}

private struct KeyPlacement {
    let hand: Hand
    let finger: Int
    let row: Int
    let column: Int
    let homeScore: Double
    let switchGroup: String?
}

private struct ProfileDefinition {
    let placements: [String: KeyPlacement]
    let sameSwitchGroups: [[String]]
    let m4gPhysicalModel: M4GPhysicalModel?
}

private struct CandidateHint: Sendable {
    let lemma: String
    let relation: MorphologyRelation
    let suffixMarker: String
    let confidence: Double
    let isSecondaryMarker: Bool

    var strength: Double {
        confidence + (isSecondaryMarker ? 0 : 0.1)
    }
}

private struct ConflictFallbackCandidate: Sendable {
    let inputKeys: [String]
    let usesSymbolNamespace: Bool
}

private struct StarredStyleModel: Sendable {
    private struct Shape: Sendable {
        let length: Int
        let handImbalance: Int
        let thumbCount: Int
    }

    private let shapes: [Shape]
    private let preferredLengths: Set<Int>
    private let averageLength: Double
    private let averageHandImbalance: Double
    private let averageThumbCount: Double

    var isEmpty: Bool {
        shapes.isEmpty
    }

    init(existingChords: [ChordEntry], definition: ProfileDefinition) {
        let starredShapes = existingChords
            .filter(\.isStarred)
            .compactMap { chord -> Shape? in
                let tokens = (chord.displayInput.isEmpty ? chord.inputKeys : chord.displayInput)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
                guard !tokens.isEmpty else { return nil }
                return Self.shape(for: tokens, definition: definition)
            }
        shapes = starredShapes
        preferredLengths = Set(starredShapes.map(\.length))
        if starredShapes.isEmpty {
            averageLength = 0
            averageHandImbalance = 0
            averageThumbCount = 0
        } else {
            averageLength = starredShapes.map { Double($0.length) }.reduce(0, +) / Double(starredShapes.count)
            averageHandImbalance = starredShapes.map { Double($0.handImbalance) }.reduce(0, +) / Double(starredShapes.count)
            averageThumbCount = starredShapes.map { Double($0.thumbCount) }.reduce(0, +) / Double(starredShapes.count)
        }
    }

    func score(for inputKeys: [String], anchorCoverage: WordAnchorCoverage, definition: ProfileDefinition) -> (bonus: Double, reason: String?) {
        guard !isEmpty else { return (0, nil) }
        let shape = Self.shape(for: inputKeys, definition: definition)
        var bonus = 0.0
        if preferredLengths.contains(shape.length) {
            bonus += 5
        } else if abs(Double(shape.length) - averageLength) <= 1 {
            bonus += 2
        }
        if abs(Double(shape.handImbalance) - averageHandImbalance) <= 1 {
            bonus += 2
        }
        if abs(Double(shape.thumbCount) - averageThumbCount) <= 1 {
            bonus += 2
        }
        let anchorDensity = Double(anchorCoverage.tokens.count) / Double(max(inputKeys.count, 1))
        if anchorDensity >= 0.6 {
            bonus += 3
        }
        return bonus > 0 ? (bonus, "Matches starred chord style.") : (0, nil)
    }

    private static func shape(for inputKeys: [String], definition: ProfileDefinition) -> Shape {
        var leftCount = 0
        var rightCount = 0
        var thumbCount = 0
        for token in inputKeys {
            guard let placement = definition.placements[token] else { continue }
            switch placement.hand {
            case .left:
                leftCount += 1
            case .right:
                rightCount += 1
            }
            if placement.finger == 4 {
                thumbCount += 1
            }
        }
        return Shape(
            length: inputKeys.count,
            handImbalance: abs(leftCount - rightCount),
            thumbCount: thumbCount
        )
    }
}

/// A chord built from your chord for the stem plus an ending key.
struct LearnedFamilyHint: Sendable {
    let base: String
    let baseKeys: [String]
    let suffix: String
    let marker: String
    let learned: Bool
}

/// What the advisor knows about you for one word.
struct PersonalScoring {
    let style: LibraryStyleModel
    let familyHint: LearnedFamilyHint?
    let neighbors: ChordNeighborIndex
    /// Times you wrote the word in the last 90 days, when known.
    let usage: Int?
    let initials: [String]
    /// Symbols you put in front of letters to tell chords apart.
    var namespaceTokens: Set<String> = []
    fileprivate var hands: HandPositionModel?
}

/// How well a chord sits under your hands, learned from the chords you use.
/// For each hand it looks at every pair of positions (switch and direction)
/// the chord presses: pairs you already press together are easy; pairs you
/// never press fall back to anatomy. The thumb moves independently of the
/// fingers, so thumb pairs are easy; neighbouring fingers moving in
/// different directions (the ring finger pushing sideways while the middle
/// finger pulls down) are hard. The letters don't matter here: `,+a+l+n` can
/// break letter rules and still sit well.
fileprivate struct HandPositionModel {
    struct Position: Hashable {
        let id: String
        let hand: String
        /// 0 pinky … 3 index, 4 thumb.
        let finger: Int
        /// 0 east, 1 north, 2 west, 3 south.
        let direction: Int
    }

    private let pairWeights: [String: Double]
    private let pairReference: Double
    /// Three positions on one hand pressed together, by weight.
    private let tripleWeights: [String: Double]
    let isTrained: Bool

    init(existingChords: [ChordEntry], uses: [String: Int]?, definition: ProfileDefinition) {
        var pairs: [String: Double] = [:]
        var triples: [String: Double] = [:]
        var trainedWeight = 0.0
        for chord in existingChords {
            let word = (chord.plainOutput ?? chord.output).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let weight = LibraryStyleModel.weight(uses: uses.map { $0[word] ?? 0 })
            guard weight >= 1 else { continue }
            let hands = Self.handPositions(chord.inputKeys, definition: definition)
            guard !hands.isEmpty else { continue }
            trainedWeight += weight
            for positions in hands.values {
                for (index, first) in positions.enumerated() {
                    for second in positions[(index + 1)...] {
                        pairs[Self.pairKey(first, second), default: 0] += weight
                    }
                }
                for triple in Self.triples(positions) {
                    triples[Self.tripleKey(triple), default: 0] += weight
                }
            }
        }
        tripleWeights = triples
        let sorted = pairs.values.sorted()
        // The 75th percentile: a pair as familiar as your usual ones.
        pairReference = sorted.isEmpty ? 1 : max(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.75))], 1)
        pairWeights = pairs
        isTrained = uses != nil && trainedWeight >= 60
    }

    static func handPositions(_ keys: [String], definition: ProfileDefinition) -> [String: [Position]] {
        var hands: [String: Set<Position>] = [:]
        for key in keys {
            guard let placement = definition.placements[key.lowercased()] else { continue }
            let position = Position(
                id: "\(placement.switchGroup ?? "\(placement.finger)-\(placement.row)")#\(placement.column)",
                hand: placement.hand.rawValue,
                finger: placement.finger,
                direction: placement.column
            )
            hands[position.hand, default: []].insert(position)
        }
        return hands.mapValues { $0.sorted { $0.id < $1.id } }
    }

    private static func triples(_ positions: [Position]) -> [[Position]] {
        guard positions.count >= 3 else { return [] }
        var result: [[Position]] = []
        for a in 0..<positions.count {
            for b in (a + 1)..<positions.count {
                for c in (b + 1)..<positions.count {
                    result.append([positions[a], positions[b], positions[c]])
                }
            }
        }
        return result
    }

    private static func tripleKey(_ triple: [Position]) -> String {
        triple.map(\.id).sorted().joined(separator: "|")
    }

    private static func pairKey(_ first: Position, _ second: Position) -> String {
        first.id < second.id ? "\(first.id)|\(second.id)" : "\(second.id)|\(first.id)"
    }

    /// For a pair you never press together: how easy it should be anyway.
    private static func anatomy(_ first: Position, _ second: Position) -> Double {
        if first.finger == 4 || second.finger == 4 { return 0.6 }
        if first.finger == second.finger { return 0.2 }
        let vertical: Set<Int> = [1, 3]
        let bothVertical = vertical.contains(first.direction) && vertical.contains(second.direction)
        if abs(first.finger - second.finger) == 1 {
            // Neighbours: fine moving the same way, hard otherwise.
            return bothVertical && first.direction == second.direction ? 0.5 : 0.1
        }
        return bothVertical ? 0.45 : 0.3
    }

    private func pairFamiliarity(_ first: Position, _ second: Position) -> Double {
        let weight = pairWeights[Self.pairKey(first, second)] ?? 0
        let learned = min(log1p(weight) / log1p(pairReference), 1)
        return max(learned, weight > 0 ? 0.3 : Self.anatomy(first, second))
    }

    /// The hardest pair on either hand, from 0 (hard) to 1 (a pair you press
    /// all the time). Nil when there isn't enough history.
    func familiarity(_ keys: [String], definition: ProfileDefinition) -> Double? {
        guard isTrained else { return nil }
        var worst = 1.0
        for positions in Self.handPositions(keys, definition: definition).values {
            for (index, first) in positions.enumerated() {
                for second in positions[(index + 1)...] {
                    worst = min(worst, pairFamiliarity(first, second))
                }
            }
            // Three keys on one hand you have never pressed together are
            // hard even when each pair is familiar.
            for triple in Self.triples(positions) where (tripleWeights[Self.tripleKey(triple)] ?? 0) == 0 {
                let thumbs = triple.filter { $0.finger == 4 }.count
                worst = min(worst, thumbs > 0 ? 0.3 : 0.2)
            }
        }
        return worst
    }

    /// From -20 (fingers you can't coordinate) to +6 (pairs you press all
    /// the time).
    func score(_ keys: [String], definition: ProfileDefinition) -> (score: Double, reason: String?) {
        guard let familiarity = familiarity(keys, definition: definition) else { return (0, nil) }
        let score = familiarity >= 0.5 ? (familiarity - 0.5) * 12 : (familiarity - 0.5) * 50
        if familiarity >= 0.8 { return (score, "Each hand presses finger pairs you already use.") }
        if familiarity <= 0.2 { return (score, "Two fingers would move in ways you never combine.") }
        return (score, nil)
    }
}

public struct SuggestionEngine: Sendable {
    private let morphologyIndex: EnglishMorphologyIndex
    private let anchorAnalyzer: WordAnchorAnalyzer

    public init(morphologyIndex: EnglishMorphologyIndex = .bundled) {
        self.morphologyIndex = morphologyIndex
        self.anchorAnalyzer = WordAnchorAnalyzer()
    }

    init(morphologyIndex: EnglishMorphologyIndex = .bundled, anchorAnalyzer: WordAnchorAnalyzer) {
        self.morphologyIndex = morphologyIndex
        self.anchorAnalyzer = anchorAnalyzer
    }

    public func adviseChord(
        for word: String,
        profile: ErgonomicProfile = .cc2A1,
        existingChords: [ChordEntry],
        bannedInputs: Set<String> = [],
        allowReplacingOutput: Bool = false,
        usage: Int? = nil,
        slotUsage: SlotUsage? = nil,
        offerReclaims: Bool = true,
        limit: Int = 10
    ) -> [Candidate] {
        let normalizedWord = word
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalizedWord.count >= 2 else { return [] }

        let existingOutputs = Set(existingChords.map { ($0.plainOutput ?? $0.output).lowercased() })
        guard allowReplacingOutput || !existingOutputs.contains(normalizedWord) else {
            return []
        }

        let stat = WordStat(
            word: normalizedWord,
            frequency: usage ?? 100,
            avgMs: 300,
            lastUsedAt: .now,
            source: "advisor"
        )
        let existingInputs = Set(existingChords.map(\.normalizedInput))
        let existingInputIdentities = Self.inputIdentities(for: existingChords)
        let definition = profileDefinition(for: profile)
        return Array(
            buildCandidates(
                for: normalizedWord,
                stat: stat,
                profile: profile,
                definition: definition,
                existingChords: existingChords,
                existingInputs: existingInputs,
                existingInputIdentities: existingInputIdentities,
                bannedInputs: bannedInputs,
                usage: usage,
                slotUsage: slotUsage,
                offerReclaims: offerReclaims
            )
            .prefix(limit)
        )
    }

    public func diagnoseRejectedCandidates(
        for word: String,
        profile: ErgonomicProfile = .cc2A1,
        existingChords: [ChordEntry],
        bannedInputs: Set<String> = [],
        allowReplacingOutput: Bool = false,
        limit: Int = 10
    ) -> [Candidate] {
        let normalizedWord = word
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedWord.count >= 2 else { return [] }

        let existingOutputs = Set(existingChords.map { ($0.plainOutput ?? $0.output).lowercased() })
        guard allowReplacingOutput || !existingOutputs.contains(normalizedWord) else {
            return []
        }

        let stat = WordStat(
            word: normalizedWord,
            frequency: 100,
            avgMs: 300,
            lastUsedAt: .now,
            source: "advisor"
        )
        let existingInputs = Set(existingChords.map(\.normalizedInput))
        let existingInputIdentities = Self.inputIdentities(for: existingChords)
        let definition = profileDefinition(for: profile)

        return Array(
            buildCandidates(
                for: normalizedWord,
                stat: stat,
                profile: profile,
                definition: definition,
                existingChords: existingChords,
                existingInputs: existingInputs,
                existingInputIdentities: existingInputIdentities,
                bannedInputs: bannedInputs,
                includeRejected: true
            )
            .filter { !$0.hardFailures.isEmpty }
            .prefix(limit)
        )
    }

    public func generateSuggestions(
        profile: ErgonomicProfile,
        words: [WordStat],
        existingChords: [ChordEntry],
        availableChords: [ChordEntry] = [],
        bannedInputs: Set<String>,
        limit: Int = 50
    ) -> [Suggestion] {
        let allAvailableChords = (existingChords + availableChords).reduce(into: [UUID: ChordEntry]()) {
            $0[$1.id] = $1
        }.map(\.value)
        let chordsByOutput = Dictionary(grouping: allAvailableChords) {
            ($0.plainOutput ?? $0.output).lowercased()
        }
        let existingInputs = Set(existingChords.map(\.normalizedInput))
        let existingInputIdentities = Self.inputIdentities(for: existingChords)
        let definition = profileDefinition(for: profile)

        return words
            .reduce(into: [Suggestion]()) { result, stat in
                let normalizedWord = stat.word.lowercased()
                guard normalizedWord.count >= 3 else { return }
                if let existingChord = chordsByOutput[normalizedWord]?.sorted(by: { lhs, rhs in
                    if (lhs.profile == profile) != (rhs.profile == profile) {
                        return lhs.profile == profile
                    }
                    return lhs.updatedAt > rhs.updatedAt
                }).first {
                    let inputKeys = existingChord.displayInput.isEmpty
                        ? existingChord.inputKeys
                        : existingChord.displayInput
                    let priorityScore = Double(stat.frequency) * max(Double(normalizedWord.count - 2), 1) * max(stat.avgMs, 100)
                    result.append(
                        Suggestion(
                            word: normalizedWord,
                            profile: profile,
                            candidates: [
                                Candidate(
                                    inputKeys: inputKeys,
                                    score: 0,
                                    hardFailures: [],
                                    softReasons: ["Already available on \(existingChord.profile.displayName)."]
                                )
                            ],
                            priorityScore: priorityScore,
                            acceptedChordId: existingChord.id
                        )
                    )
                    return
                }

                let candidates = buildCandidates(
                    for: normalizedWord,
                    stat: stat,
                    profile: profile,
                    definition: definition,
                    existingChords: existingChords,
                    existingInputs: existingInputs,
                    existingInputIdentities: existingInputIdentities,
                    bannedInputs: bannedInputs
                )

                guard !candidates.isEmpty else { return }

                let priorityScore = Double(stat.frequency) * max(Double(normalizedWord.count - 2), 1) * max(stat.avgMs, 100)
                result.append(
                    Suggestion(
                        word: normalizedWord,
                        profile: profile,
                        candidates: Array(candidates.prefix(3)),
                        priorityScore: priorityScore
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.priorityScore == rhs.priorityScore {
                    return lhs.word < rhs.word
                }
                return lhs.priorityScore > rhs.priorityScore
            }
            .prefix(limit)
            .map { $0 }
    }

    private func buildCandidates(
        for word: String,
        stat: WordStat,
        profile: ErgonomicProfile,
        definition: ProfileDefinition,
        existingChords: [ChordEntry],
        existingInputs: Set<String>,
        existingInputIdentities: Set<String>,
        bannedInputs: Set<String>,
        includeRejected: Bool = false,
        usage: Int? = nil,
        slotUsage: SlotUsage? = nil,
        offerReclaims: Bool = true
    ) -> [Candidate] {
        let anchorAnalysis = anchorAnalyzer.analysis(for: word)
        // A phrase leans on each word's first letter.
        let phraseWords = word.split(separator: " ").map(String.init)
        let isPhrase = phraseWords.count > 1
        let initials = orderedUnique(phraseWords.compactMap { $0.first.map(String.init) })
            .filter { definition.placements[$0] != nil }
        let priorityLetters = orderedUnique((isPhrase ? initials : []) + anchorAnalysis.orderedTokens)
            .filter { $0 != " " && $0 != "space" }
        let style = LibraryStyleModel(existingChords: existingChords, uses: slotUsage?.uses)
        let hands = HandPositionModel(existingChords: existingChords, uses: slotUsage?.uses, definition: definition)
        let family = FamilyMarkerModel(existingChords: existingChords)
        let neighbors = ChordNeighborIndex(existingChords: existingChords)
        var familyHints: [[String]: LearnedFamilyHint] = [:]
        let maxBaseLength = min(priorityLetters.count, 5)
        var candidateInputs: Set<[String]> = []
        var candidateHints: [[String]: CandidateHint] = [:]
        var longFallbackInputs: Set<[String]> = []
        var conflictFallbackInputs: Set<[String]> = []
        var symbolNamespaceInputs: Set<[String]> = []
        let starredStyleModel = StarredStyleModel(existingChords: existingChords, definition: definition)

        func insertCandidate(_ keys: [String], hint: CandidateHint? = nil) {
            let normalizedKeys = keys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            guard normalizedKeys.count >= 2 else { return }
            candidateInputs.insert(normalizedKeys)
            if let hint {
                if let existing = candidateHints[normalizedKeys], existing.strength >= hint.strength {
                    return
                }
                candidateHints[normalizedKeys] = hint
            }
        }

        for (keys, hint) in familyCandidateHints(for: word, existingChords: existingChords) {
            insertCandidate(keys, hint: hint)
        }

        // Your chord for the stem plus the key you use for this ending.
        if !isPhrase {
            for extensionCandidate in family.extensions(for: word) {
                for marker in extensionCandidate.markers {
                    let keys = extensionCandidate.baseKeys + [marker.key]
                    guard keys.count <= 6 else { continue }
                    insertCandidate(keys)
                    let normalized = keys.map { $0.lowercased() }
                    if familyHints[normalized] == nil {
                        familyHints[normalized] = LearnedFamilyHint(
                            base: extensionCandidate.base,
                            baseKeys: extensionCandidate.baseKeys,
                            suffix: extensionCandidate.suffix,
                            marker: marker.key,
                            learned: marker.learned
                        )
                    }
                }
            }
        }

        // A symbol key in front of the word's own letters (`/+p+t+c` when
        // p+t+c is taken) stays easy to remember. Use the symbols your
        // library already uses that way, most used first.
        let namespaceTokens = learnedNamespaceTokens(existingChords)
        if !initials.isEmpty, !isPhrase {
            let rest = Array(priorityLetters.filter { !initials.contains($0) }.prefix(6))
            for size in 1...min(2, max(rest.count, 1)) {
                for combo in combinations(of: rest, taking: size) {
                    let letters = initials + combo
                    guard existingInputs.contains(ChordEntry.normalizeInputKeys(letters)) else { continue }
                    for namespace in namespaceTokens {
                        insertCandidate([namespace] + letters)
                    }
                }
            }
        }

        // Where you have your own key for this ending, the built-in
        // morphology marker for the same stem would only compete with it.
        let learnedMarkersByBase = Dictionary(
            familyHints.values.filter(\.learned).map { ($0.base, [$0.marker]) },
            uniquingKeysWith: +
        )
        for (keys, hint) in candidateHints {
            if let learned = learnedMarkersByBase[hint.lemma], !learned.contains(hint.suffixMarker) {
                candidateHints.removeValue(forKey: keys)
            }
        }

        // Most of your chords include the first letter (every word's, for a
        // phrase), so build plenty of candidates around it.
        if !initials.isEmpty {
            let rest = Array(priorityLetters.filter { !initials.contains($0) }.prefix(7))
            for size in 0...min(3, rest.count) {
                for combo in combinations(of: rest, taking: size) where initials.count + combo.count <= 5 {
                    insertCandidate(initials + combo)
                    if isPhrase {
                        insertCandidate(initials + combo + ["space"])
                    }
                }
            }
        }

        for alias in memorableAliases(for: word, priorityLetters: priorityLetters) {
            insertCandidate(alias)
        }

        for anchoredCandidate in anchorSeedCandidates(anchorAnalysis: anchorAnalysis, priorityLetters: priorityLetters) {
            insertCandidate(anchoredCandidate)
        }

        for length in 2...max(2, min(4, maxBaseLength)) {
            for combo in combinations(of: Array(priorityLetters.prefix(6)), taking: length) {
                insertCandidate(combo)
            }
        }

        if word.hasSuffix("ly"), !priorityLetters.contains("l") {
            for combo in combinations(of: Array(priorityLetters.prefix(5)), taking: min(3, priorityLetters.count)) {
                insertCandidate(Array((combo + ["l"]).prefix(4)))
            }
        }

        if word.containsRepeatedLetters, profile == .cc2A1 {
            for combo in combinations(of: Array(priorityLetters.prefix(4)), taking: min(3, priorityLetters.count)) {
                insertCandidate(["dup"] + combo)
            }
        }

        if word.hasSuffix("tion") || word.hasSuffix("sion") {
            for combo in combinations(of: Array(priorityLetters.prefix(4)), taking: min(3, priorityLetters.count)) {
                insertCandidate([","] + combo)
            }
        }

        func scoredCandidates() -> [Candidate] {
            candidateInputs
            .map {
                scoreCandidate(
                    $0,
                    hint: candidateHints[$0],
                    word: word,
                    anchorAnalysis: anchorAnalysis,
                    stat: stat,
                    profile: profile,
                    definition: definition,
                    existingInputs: existingInputs,
                    existingInputIdentities: existingInputIdentities,
                    bannedInputs: bannedInputs,
                    isLongFallback: longFallbackInputs.contains($0),
                    isConflictFallback: conflictFallbackInputs.contains($0),
                    usesSymbolNamespace: symbolNamespaceInputs.contains($0),
                    starredStyleModel: starredStyleModel,
                    personal: PersonalScoring(
                        style: style,
                        familyHint: familyHints[$0],
                        neighbors: neighbors,
                        usage: usage,
                        initials: isPhrase ? initials : Array(initials.prefix(1)),
                        namespaceTokens: Set(namespaceTokens),
                        hands: hands
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.inputKeys.joined() < rhs.inputKeys.joined()
                }
                return lhs.score > rhs.score
            }
        }

        var scored = scoredCandidates()
        if shouldGenerateSmartLongFallback(scoredCandidates: scored, anchorAnalysis: anchorAnalysis) {
            for candidate in smartLongFallbackCandidates(anchorAnalysis: anchorAnalysis, priorityLetters: priorityLetters, definition: definition) {
                insertCandidate(candidate)
                longFallbackInputs.insert(candidate)
            }
            scored = scoredCandidates()
        }

        if scored.filter({ $0.hardFailures.isEmpty }).count < 3 {
            for fallback in conflictRelaxedFallbackCandidates(
                priorityLetters: priorityLetters,
                definition: definition
            ) {
                insertCandidate(fallback.inputKeys)
                conflictFallbackInputs.insert(fallback.inputKeys)
                if fallback.usesSymbolNamespace {
                    symbolNamespaceInputs.insert(fallback.inputKeys)
                }
            }
            scored = scoredCandidates()
        }

        if !includeRejected, offerReclaims, let slotUsage {
            return withReclaims(
                scored,
                word: word,
                usage: usage,
                slotUsage: slotUsage,
                profile: profile,
                existingChords: existingChords,
                bannedInputs: bannedInputs
            )
        }
        return scored
            .filter { includeRejected || $0.hardFailures.isEmpty }
    }

    /// Adds, second in line, keys that only fail because a chord you barely
    /// write holds them, when they are clearly better than any free keys.
    /// That chord moves to the next best keys; nothing is deleted. Usage over
    /// all your history decides, not recency, so words you use for one
    /// project at a time keep their chords.
    private func withReclaims(
        _ scored: [Candidate],
        word: String,
        usage: Int?,
        slotUsage: SlotUsage,
        profile: ErgonomicProfile,
        existingChords: [ChordEntry],
        bannedInputs: Set<String>
    ) -> [Candidate] {
        var valid = scored.filter { $0.hardFailures.isEmpty }
        guard slotUsage.historyDays >= 30, let bestFree = valid.first else { return valid }
        let occupants = Dictionary(
            existingChords.map { (Set($0.inputKeys.map { $0.lowercased() }), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let newWordUses = usage ?? 0
        let isFallback: (Candidate) -> Bool = { candidate in
            candidate.softReasons.contains {
                $0.contains("Conflict-free mnemonic fallback") || $0.contains("Long ergonomic fallback")
            }
        }
        let bestComparable = valid.first { !isFallback($0) }?.score ?? (bestFree.score - 16)
        var reclaims: [Candidate] = []
        for candidate in scored where !candidate.hardFailures.isEmpty {
            guard reclaims.count < 2 else { break }
            guard candidate.hardFailures.allSatisfy({ $0.contains("already exists") }),
                  let occupant = occupants[Set(candidate.inputKeys)],
                  !occupant.isStarred,
                  occupant.actionFlags.isEmpty,
                  slotUsage.now.timeIntervalSince(occupant.createdAt) > 30 * 86_400 else { continue }
            let occupantWord = (occupant.plainOutput ?? occupant.output).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = occupantWord.lowercased()
            guard !key.isEmpty, key != word else { continue }
            let uses = slotUsage.uses[key] ?? 0
            // About once a month or less, and this word matters more.
            guard uses * 30 <= slotUsage.historyDays, newWordUses >= uses * 3 + 3 else { continue }
            // Worth offering when these keys are about as good as the best
            // free ones; it comes second either way. Last-resort chords carry
            // bonuses for being the only option left, which don't count here.
            guard candidate.score >= bestComparable - 2 else { continue }
            let score = candidate.score - 6
            let remaining = existingChords.filter { $0.id != occupant.id } + [
                ChordEntry(inputKeys: candidate.inputKeys, output: word, profile: profile, deploymentTarget: .device, source: "reclaim")
            ]
            guard let moved = adviseChord(
                for: key,
                profile: profile,
                existingChords: remaining,
                bannedInputs: bannedInputs,
                allowReplacingOutput: true,
                limit: 1
            ).first else { continue }
            let times = uses == 0 ? "never written" : "written \(uses)×"
            let note = "Takes these keys from “\(occupantWord)” (\(times) in \(slotUsage.historyDays) days you typed); it moves to \(moved.inputKeys.joined(separator: "+"))."
            reclaims.append(Candidate(
                inputKeys: candidate.inputKeys,
                score: score,
                hardFailures: [],
                softReasons: [note] + candidate.softReasons,
                reclaim: ChordReclaim(
                    chordID: occupant.id,
                    output: occupantWord,
                    uses: uses,
                    historyDays: slotUsage.historyDays,
                    movedKeys: moved.inputKeys
                )
            ))
        }
        guard !reclaims.isEmpty else { return valid }
        // Offered, never forced: free keys stay first.
        valid.insert(contentsOf: reclaims, at: 1)
        return valid
    }

    private func learnedNamespaceTokens(_ chords: [ChordEntry]) -> [String] {
        var counts: [String: Int] = [:]
        for chord in chords {
            for token in chord.inputKeys.map({ $0.lowercased() }) where Self.shortWordNamespaceTokens.contains(token) {
                counts[token, default: 0] += 1
            }
        }
        let learned = counts.filter { $0.value >= 3 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        // Every marker you use; the hand model picks the one that sits well.
        return Array((learned.isEmpty ? Self.shortWordNamespaceTokens : learned).prefix(6))
    }

    private func familyCandidateHints(
        for word: String,
        existingChords: [ChordEntry]
    ) -> [([String], CandidateHint)] {
        let matches = morphologyIndex.matches(for: word)
        guard !matches.isEmpty else { return [] }

        let chordsByOutput = Dictionary(grouping: existingChords) { chord in
            (chord.plainOutput ?? chord.output).lowercased()
        }
        var results: [([String], CandidateHint)] = []

        for match in matches {
            guard let baseChords = chordsByOutput[match.lemma],
                  let primaryMarker = match.suffixMarker,
                  !primaryMarker.isEmpty else {
                continue
            }

            for baseChord in baseChords {
                let baseInput = (baseChord.displayInput.isEmpty ? baseChord.inputKeys : baseChord.displayInput)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
                guard !baseInput.isEmpty, baseInput.count < 6 else { continue }

                insertFamilyCandidate(
                    baseInput: baseInput,
                    marker: primaryMarker,
                    match: match,
                    isSecondaryMarker: false,
                    into: &results
                )

                if match.relation == .tion || match.relation == .ation || match.relation == .sion {
                    insertFamilyCandidate(
                        baseInput: baseInput,
                        marker: ",",
                        match: match,
                        isSecondaryMarker: true,
                        into: &results
                    )
                }
            }
        }

        return results
    }

    private func insertFamilyCandidate(
        baseInput: [String],
        marker: String,
        match: MorphologyMatch,
        isSecondaryMarker: Bool,
        into results: inout [([String], CandidateHint)]
    ) {
        let normalizedMarker = marker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedMarker.isEmpty, !baseInput.contains(normalizedMarker), baseInput.count < 6 else { return }
        let candidate = baseInput + [normalizedMarker]
        guard candidate.count <= 6 else { return }
        results.append(
            (
                candidate,
                CandidateHint(
                    lemma: match.lemma,
                    relation: match.relation,
                    suffixMarker: normalizedMarker,
                    confidence: match.confidence,
                    isSecondaryMarker: isSecondaryMarker
                )
            )
        )
    }

    private func scoreCandidate(
        _ inputKeys: [String],
        hint: CandidateHint?,
        word: String,
        anchorAnalysis: WordAnchorAnalysis,
        stat: WordStat,
        profile: ErgonomicProfile,
        definition: ProfileDefinition,
        existingInputs: Set<String>,
        existingInputIdentities: Set<String>,
        bannedInputs: Set<String>,
        isLongFallback: Bool,
        isConflictFallback: Bool,
        usesSymbolNamespace: Bool,
        starredStyleModel: StarredStyleModel,
        personal: PersonalScoring? = nil
    ) -> Candidate {
        let normalizedKeys = inputKeys.map { $0.lowercased() }
        let normalizedInput = ChordEntry.normalizeInputKeys(normalizedKeys)
        let rawInputIdentity = profile == .cc2A1
            ? ActionCodec.chordActions(forTokens: normalizedKeys).map(ActionCodec.stringifyChordActions)
            : nil
        var hardFailures: [String] = []
        var softReasons: [String] = []
        /// Reasons shown first: why this chord suits you.
        var leadReasons: [String] = []
        var score = 100.0

        if let familyHint = personal?.familyHint {
            // Your own habit outranks the built-in morphology marker (+32) and
            // the anchor bonus a letter of the ending gets.
            score += familyHint.learned ? 50 : 14
            let base = familyHint.baseKeys.joined(separator: "+")
            leadReasons.append(familyHint.learned
                ? "Extends \(familyHint.base) (\(base)) with `\(familyHint.marker)`, like your other -\(familyHint.suffix) words."
                : "Extends \(familyHint.base) (\(base)) with `\(familyHint.marker)` for -\(familyHint.suffix).")
        }

        if let hint {
            score += 18
            if hint.confidence >= 0.9 {
                score += 8
            }
            if normalizedKeys.contains(hint.suffixMarker) {
                score += 6
            }
            let markerText = hint.isSecondaryMarker ? "namespace" : "marker"
            leadReasons.append("Extends \(hint.lemma) with \(hint.relation.displayName) \(markerText) `\(hint.suffixMarker)`.")
        }

        if Set(normalizedKeys).count != normalizedKeys.count {
            hardFailures.append("Duplicate physical key in candidate.")
        }
        if let rawInputIdentity, existingInputIdentities.contains(rawInputIdentity) {
            hardFailures.append("Raw chord input already exists.")
        } else if existingInputs.contains(normalizedInput) {
            hardFailures.append("Chord input already exists.")
        }
        if bannedInputs.contains(normalizedInput) {
            hardFailures.append("Chord input is banned.")
        }

        if let m4gPhysicalModel = definition.m4gPhysicalModel {
            if rawInputIdentity == nil {
                hardFailures.append("Unsupported M4G action in candidate.")
            }

            for token in normalizedKeys where m4gPhysicalModel.bestPlacement(for: token) == nil {
                hardFailures.append("Unsupported M4G physical action: \(token).")
            }

            hardFailures.append(contentsOf: m4gPhysicalModel.hardConflictReasons(for: normalizedKeys))
            // A diagonal press fires two directions of one switch. It works
            // (a rare chord like c+k), but it isn't something to learn for
            // new chords, so suggestions never need one. Chords you enter
            // yourself are still accepted.
            for diagonal in m4gPhysicalModel.diagonalPresses(for: normalizedKeys) {
                hardFailures.append(diagonal)
            }
        }

        var seenFingers: [String: Int] = [:]
        for token in normalizedKeys {
            guard let placement = definition.placements[token] else { continue }
            let fingerKey = "\(placement.hand)-\(placement.finger)"
            seenFingers[fingerKey, default: 0] += 1
            score += placement.homeScore
        }

        for (fingerKey, count) in seenFingers where count > 1 {
            score -= Double(count - 1) * 8
            softReasons.append("Same-finger load on \(fingerKey).")
        }

        if normalizedKeys.count > 4 {
            score -= Double(normalizedKeys.count - 4) * 8
        }

        let ansiProfiles: Set<ErgonomicProfile> = [.ansiQwerty, .ansiColemak, .ansiColemakDH]
        if ansiProfiles.contains(profile), normalizedKeys.contains("x") {
            score -= 6
            softReasons.append("Uses `x`, which is a stretch on ANSI layouts.")
        }

        if let usage = personal?.usage {
            // Two-key chords are few; spend them on words you write a lot.
            if normalizedKeys.count == 2, usage < 40 {
                score -= 14
                leadReasons.append("Two-key chords are scarce; you wrote this \(usage)× in 90 days.")
            } else if normalizedKeys.count == 2, usage >= 300 {
                score += 6
                leadReasons.append("You write this often enough to earn a two-key chord.")
            }
        } else if normalizedKeys.count == 2, stat.frequency < 5, word.count < 6 {
            score -= 12
            softReasons.append("Two-key chords are premium; this word is not valuable enough yet.")
        }

        if let personal {
            // `/+p+t+c`: the word's letters, already used by another chord,
            // plus one of your marker symbols.
            let markers = normalizedKeys.filter(personal.namespaceTokens.contains)
            if markers.count == 1, let marker = markers.first {
                let letters = normalizedKeys.filter { $0 != marker }
                if letters.count >= 2,
                   letters.allSatisfy({ $0.count == 1 && word.contains($0) }),
                   existingInputs.contains(ChordEntry.normalizeInputKeys(letters)) {
                    // As common as markers are in your own chords: a clean
                    // chord wins unless you use markers a lot.
                    if !usesSymbolNamespace, personal.style.isTrained {
                        score += 30 * personal.style.markerRate - 6
                    }
                    leadReasons.append("Keeps \(letters.joined(separator: "+")) from the word, with `\(marker)` to tell it apart.")
                }
            }
            let style = personal.style.score(keys: normalizedKeys, word: word, initials: personal.initials)
            score += style.score
            leadReasons.append(contentsOf: style.reasons)
            if let hands = personal.hands?.score(normalizedKeys, definition: definition) {
                score += hands.score
                if let reason = hands.reason { softReasons.insert(reason, at: 0) }
            }
            let close = personal.neighbors.neighbors(of: normalizedKeys, word: word)
            if let first = close.first {
                score -= min(Double(close.count) * 3, 9)
                softReasons.append("One key away from “\(first)”: a partial press could type it.")
            }
        }

        if word.hasSuffix("ly"), !normalizedKeys.contains("l") {
            score -= 4
            softReasons.append("Missing `l` marker for a likely -ly family chord.")
        } else if word.hasSuffix("ly"), normalizedKeys.contains("l") {
            score += 3
            softReasons.append("Keeps the -ly family hint.")
        }

        if word.containsRepeatedLetters, profile == .cc2A1, normalizedKeys.first == "dup" {
            let dupBonus = word.count > 8 ? 4.0 : 12.0
            score += dupBonus
            softReasons.append("Uses `dup` for repeated-letter disambiguation.")
        }

        if word.hasSuffix("tion") || word.hasSuffix("sion"), normalizedKeys.first == "," {
            score += 4
            softReasons.append("Uses comma namespace for a -tion/-sion family word.")
        }

        let anchorCoverage = anchorAnalysis.coverage(for: normalizedKeys)
        score += anchorCoverage.scoreBonus
        if anchorCoverage.tokens.isEmpty {
            softReasons.append("Anchor coverage: none.")
        } else {
            softReasons.append("Anchor coverage: \(anchorCoverage.tokens.joined(separator: ", ")).")
        }

        if isLongFallback {
            score += 10
            softReasons.append("Long ergonomic fallback.")
        }

        if isConflictFallback {
            score += 8
            score -= Double(max(normalizedKeys.count - 2, 0)) * 12
            softReasons.append("Conflict-free mnemonic fallback.")
        }

        if usesSymbolNamespace {
            score += 8
            softReasons.append("Uses a short-word symbol namespace from the existing M4G library style.")
        }

        let starredStyle = starredStyleModel.score(for: normalizedKeys, anchorCoverage: anchorCoverage, definition: definition)
        if let reason = starredStyle.reason {
            score += starredStyle.bonus
            softReasons.append(reason)
        }

        return Candidate(
            inputKeys: normalizedKeys,
            score: score,
            hardFailures: hardFailures,
            softReasons: leadReasons + softReasons
        )
    }

    private func prioritizedLetters(for word: String) -> [String] {
        anchorAnalyzer.analysis(for: word).orderedTokens
    }

    private func memorableAliases(for word: String, priorityLetters: [String]) -> [[String]] {
        let letters = word.unicodeScalars
            .filter { CharacterSet.letters.contains($0) }
            .map { String($0).lowercased() }
        guard !letters.isEmpty else { return [] }

        var aliases: Set<[String]> = []
        func insertUnique(_ values: [String]) {
            let unique = values.reduce(into: [String]()) { result, token in
                if !result.contains(token) {
                    result.append(token)
                }
            }
            if unique.count >= 2 {
                aliases.insert(unique)
            }
        }

        insertUnique([letters.first!, letters.last!])
        if letters.count >= 3 {
            insertUnique([letters[0], letters[1], letters.last!])
        }
        insertUnique(Array(priorityLetters.prefix(3)))
        if word.containsRepeatedLetters {
            insertUnique(["dup"] + Array(priorityLetters.prefix(3)))
        }
        return Array(aliases)
    }

    private func anchorSeedCandidates(anchorAnalysis: WordAnchorAnalysis, priorityLetters: [String]) -> [[String]] {
        let strongestAnchors = anchorAnalysis.strongestTokens(limit: min(3, priorityLetters.count))
        guard strongestAnchors.count >= 2 else { return [] }

        let requiredAnchors = Array(strongestAnchors.prefix(2))
        var seeds: Set<[String]> = [requiredAnchors]
        let pool = priorityLetters.filter { !requiredAnchors.contains($0) }
        if priorityLetters.count >= 3 {
            for length in 3...min(4, priorityLetters.count) {
                let tailCount = length - requiredAnchors.count
                for tail in combinations(of: Array(pool.prefix(5)), taking: tailCount) {
                    seeds.insert(requiredAnchors + tail)
                }
            }
        }

        if let suffixMarker = anchorAnalysis.suffixMarker,
           priorityLetters.contains(suffixMarker),
           !requiredAnchors.contains(suffixMarker) {
            let suffixRequired = [suffixMarker] + Array(requiredAnchors.prefix(1))
            if suffixRequired.count >= 2 {
                seeds.insert(Array(suffixRequired))
                let suffixPool = priorityLetters.filter { !suffixRequired.contains($0) }
                for tail in combinations(of: Array(suffixPool.prefix(5)), taking: 1) {
                    seeds.insert(Array(suffixRequired) + tail)
                }
            }
        }

        return Array(seeds)
    }

    private func shouldGenerateSmartLongFallback(scoredCandidates: [Candidate], anchorAnalysis: WordAnchorAnalysis) -> Bool {
        let validCandidates = scoredCandidates.filter { $0.hardFailures.isEmpty }
        if validCandidates.isEmpty {
            return true
        }

        let coreCount = anchorAnalysis.orderedTokens.count >= 5 ? 4 : min(3, anchorAnalysis.orderedTokens.count)
        guard coreCount >= 3 else { return false }

        let coreAnchors = Set(anchorAnalysis.strongestTokens(limit: coreCount))
        let validCoreCandidateExists = validCandidates.contains { candidate in
            coreAnchors.isSubset(of: Set(candidate.inputKeys))
        }
        if validCoreCandidateExists {
            return false
        }

        return scoredCandidates.contains { candidate in
            !candidate.hardFailures.isEmpty && coreAnchors.isSubset(of: Set(candidate.inputKeys))
        }
    }

    private func smartLongFallbackCandidates(
        anchorAnalysis: WordAnchorAnalysis,
        priorityLetters: [String],
        definition: ProfileDefinition
    ) -> [[String]] {
        let coreCount = anchorAnalysis.orderedTokens.count >= 5 ? 4 : min(3, anchorAnalysis.orderedTokens.count)
        guard coreCount >= 3 else { return [] }

        let coreAnchors = anchorAnalysis.strongestTokens(limit: coreCount)
        let availableTokens = Set(definition.placements.keys)
        let pool = orderedUnique(
            priorityLetters
            + Self.ergonomicFallbackTokens
        )
        .filter { token in
            availableTokens.contains(token) && !coreAnchors.contains(token)
        }

        let minimumLength = min(6, max(4, coreAnchors.count + 1))
        let maximumLength = min(6, coreAnchors.count + 2)
        guard minimumLength <= maximumLength else { return [] }

        var candidates: Set<[String]> = []
        for length in minimumLength...maximumLength {
            let tailCount = length - coreAnchors.count
            guard tailCount > 0 else { continue }
            for tail in combinations(of: Array(pool.prefix(12)), taking: tailCount) {
                candidates.insert(coreAnchors + tail)
            }
        }
        return Array(candidates)
    }

    private func conflictRelaxedFallbackCandidates(
        priorityLetters: [String],
        definition: ProfileDefinition
    ) -> [ConflictFallbackCandidate] {
        let availableTokens = Set(definition.placements.keys)
        let anchors = orderedUnique(priorityLetters)
            .filter(availableTokens.contains)
        guard !anchors.isEmpty else { return [] }

        func isPhysicallyValid(_ tokens: [String]) -> Bool {
            guard tokens.count >= 2,
                  Set(tokens).count == tokens.count,
                  tokens.allSatisfy(availableTokens.contains) else {
                return false
            }
            if let physicalModel = definition.m4gPhysicalModel {
                return ActionCodec.chordActions(forTokens: tokens) != nil
                    && physicalModel.hardConflictReasons(for: tokens).isEmpty
                    && physicalModel.diagonalPresses(for: tokens).isEmpty
            }
            return true
        }

        let anchorPool = Array(anchors.prefix(6))
        var compatibleAnchorSets: [[String]] = []
        for count in stride(from: min(3, anchorPool.count), through: 1, by: -1) {
            let compatible = combinations(of: anchorPool, taking: count).filter { anchors in
                if let physicalModel = definition.m4gPhysicalModel {
                    return anchors.allSatisfy(availableTokens.contains)
                        && physicalModel.hardConflictReasons(for: anchors).isEmpty
                        && physicalModel.diagonalPresses(for: anchors).isEmpty
                }
                return anchors.allSatisfy(availableTokens.contains)
            }
            if !compatible.isEmpty {
                compatibleAnchorSets = compatible
                break
            }
        }
        guard !compatibleAnchorSets.isEmpty else { return [] }

        let namespaceTokens = Self.shortWordNamespaceTokens.filter(availableTokens.contains)
        let anchorTokenSet = Set(anchors)
        let ergonomicTokens = Self.ergonomicFallbackTokens.filter { token in
            availableTokens.contains(token) && !anchorTokenSet.contains(token)
        }
        var seen: Set<[String]> = []
        var results: [ConflictFallbackCandidate] = []

        func append(_ inputKeys: [String], usesSymbolNamespace: Bool) {
            guard isPhysicallyValid(inputKeys), seen.insert(inputKeys).inserted else { return }
            results.append(
                ConflictFallbackCandidate(
                    inputKeys: inputKeys,
                    usesSymbolNamespace: usesSymbolNamespace
                )
            )
        }

        for anchors in compatibleAnchorSets.prefix(12) {
            for namespace in namespaceTokens {
                append([namespace] + anchors, usesSymbolNamespace: true)
            }
            for token in ergonomicTokens.prefix(14) {
                append(anchors + [token], usesSymbolNamespace: false)
            }

            // Keep enough three-key alternatives to survive occupied or banned
            // two-key inputs without reintroducing mutually exclusive anchors.
            for namespace in namespaceTokens.prefix(3) {
                for token in ergonomicTokens.prefix(8) {
                    append([namespace] + anchors + [token], usesSymbolNamespace: true)
                }
            }
            for pair in combinations(of: Array(ergonomicTokens.prefix(10)), taking: 2) {
                append(anchors + pair, usesSymbolNamespace: false)
            }
        }

        return results
    }

    private func orderedUnique(_ tokens: [String]) -> [String] {
        tokens.reduce(into: [String]()) { result, token in
            let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !result.contains(normalized) else { return }
            result.append(normalized)
        }
    }

    private func combinations(of elements: [String], taking count: Int) -> [[String]] {
        guard count > 0 else { return [[]] }
        guard elements.count >= count else { return [] }
        if count == 1 {
            return elements.map { [$0] }
        }
        if elements.count == count {
            return [elements]
        }

        let head = elements[0]
        let tail = Array(elements.dropFirst())
        let withHead = combinations(of: tail, taking: count - 1).map { [head] + $0 }
        let withoutHead = combinations(of: tail, taking: count)
        return withHead + withoutHead
    }

    private static let ergonomicFallbackTokens = [
        "i", "e", "o", "n", "l", "d", "h", "f", "p", "c", "u", "y", "w", "g", "k", "b", "j", "q", "x", "z"
    ]

    private static let shortWordNamespaceTokens = [".", "'", "`", ",", ";", "/"]

    private func profileDefinition(for profile: ErgonomicProfile) -> ProfileDefinition {
        switch profile {
        case .cc2A1:
            return m4gProfileDefinition()
        case .ansiQwerty, .ansiColemak, .ansiColemakDH:
            return ProfileDefinition(
                placements: ansiPlacements(),
                sameSwitchGroups: [],
                m4gPhysicalModel: nil
            )
        }
    }

    private func m4gProfileDefinition() -> ProfileDefinition {
        let physicalModel = M4GPhysicalModel.defaultA1
        var placements: [String: KeyPlacement] = [:]

        for (token, physicalPlacement) in physicalModel.bestPlacementsByToken {
            placements[token] = KeyPlacement(
                hand: physicalPlacement.hand == .left ? .left : .right,
                finger: Self.fingerIndex(for: physicalPlacement.finger),
                row: Self.rowIndex(for: physicalPlacement),
                column: Self.columnIndex(for: physicalPlacement.direction),
                homeScore: physicalPlacement.homeScore,
                switchGroup: physicalPlacement.switchID
            )
        }

        return ProfileDefinition(
            placements: placements,
            sameSwitchGroups: physicalModel.sameSwitchGroups,
            m4gPhysicalModel: physicalModel
        )
    }

    private static func inputIdentities(for chords: [ChordEntry]) -> Set<String> {
        Set(chords.compactMap { chord in
            if let encodedInput = chord.encodedInput {
                return encodedInput
            }
            if let rawRecord = chord.rawRecord {
                return rawRecord.encodedInput
            }
            return nil
        })
    }

    private static func fingerIndex(for finger: M4GFinger) -> Int {
        switch finger {
        case .pinky: 0
        case .ring: 1
        case .middle: 2
        case .index: 3
        case .thumb: 4
        }
    }

    private static func rowIndex(for placement: M4GActionPlacement) -> Int {
        switch placement.finger {
        case .thumb:
            return placement.switchID.contains("lower") ? 3 : 2
        case .ring, .middle:
            return placement.switchID.contains("aux") ? 1 : 0
        case .pinky, .index:
            return 1
        }
    }

    private static func columnIndex(for direction: M4GDirection) -> Int {
        switch direction {
        case .east: 0
        case .north: 1
        case .west: 2
        case .south: 3
        }
    }

    private func ansiPlacements() -> [String: KeyPlacement] {
        [
            "a": .init(hand: .left, finger: 0, row: 1, column: 0, homeScore: 3, switchGroup: nil),
            "b": .init(hand: .left, finger: 3, row: 2, column: 4, homeScore: 0, switchGroup: nil),
            "c": .init(hand: .left, finger: 2, row: 2, column: 2, homeScore: 1, switchGroup: nil),
            "d": .init(hand: .left, finger: 2, row: 1, column: 2, homeScore: 3, switchGroup: nil),
            "e": .init(hand: .left, finger: 2, row: 0, column: 2, homeScore: 2, switchGroup: nil),
            "f": .init(hand: .left, finger: 3, row: 1, column: 3, homeScore: 3, switchGroup: nil),
            "g": .init(hand: .left, finger: 3, row: 1, column: 4, homeScore: 2, switchGroup: nil),
            "h": .init(hand: .right, finger: 3, row: 1, column: 5, homeScore: 2, switchGroup: nil),
            "i": .init(hand: .right, finger: 2, row: 0, column: 7, homeScore: 2, switchGroup: nil),
            "j": .init(hand: .right, finger: 3, row: 1, column: 6, homeScore: 3, switchGroup: nil),
            "k": .init(hand: .right, finger: 2, row: 1, column: 7, homeScore: 3, switchGroup: nil),
            "l": .init(hand: .right, finger: 1, row: 1, column: 8, homeScore: 3, switchGroup: nil),
            "m": .init(hand: .right, finger: 3, row: 2, column: 6, homeScore: 1, switchGroup: nil),
            "n": .init(hand: .right, finger: 3, row: 2, column: 5, homeScore: 1, switchGroup: nil),
            "o": .init(hand: .right, finger: 1, row: 0, column: 8, homeScore: 2, switchGroup: nil),
            "p": .init(hand: .right, finger: 0, row: 0, column: 9, homeScore: 1, switchGroup: nil),
            "q": .init(hand: .left, finger: 0, row: 0, column: 0, homeScore: 1, switchGroup: nil),
            "r": .init(hand: .left, finger: 3, row: 0, column: 3, homeScore: 2, switchGroup: nil),
            "s": .init(hand: .left, finger: 1, row: 1, column: 1, homeScore: 3, switchGroup: nil),
            "t": .init(hand: .left, finger: 3, row: 0, column: 4, homeScore: 2, switchGroup: nil),
            "u": .init(hand: .right, finger: 3, row: 0, column: 6, homeScore: 2, switchGroup: nil),
            "v": .init(hand: .left, finger: 3, row: 2, column: 3, homeScore: 1, switchGroup: nil),
            "w": .init(hand: .left, finger: 1, row: 0, column: 1, homeScore: 1, switchGroup: nil),
            "x": .init(hand: .left, finger: 1, row: 2, column: 1, homeScore: 0, switchGroup: nil),
            "y": .init(hand: .right, finger: 3, row: 0, column: 5, homeScore: 2, switchGroup: nil),
            "z": .init(hand: .left, finger: 0, row: 2, column: 0, homeScore: 0, switchGroup: nil),
            "'": .init(hand: .right, finger: 0, row: 1, column: 9, homeScore: 1, switchGroup: nil),
            ",": .init(hand: .right, finger: 2, row: 2, column: 7, homeScore: 1, switchGroup: nil),
            ";": .init(hand: .right, finger: 0, row: 1, column: 9, homeScore: 1, switchGroup: nil),
            "/": .init(hand: .right, finger: 0, row: 2, column: 9, homeScore: 0, switchGroup: nil),
            "dup": .init(hand: .right, finger: 0, row: 2, column: 10, homeScore: 0, switchGroup: nil)
        ]
    }
}

private extension String {
    var containsRepeatedLetters: Bool {
        var seen: Set<Character> = []
        for char in self where char.isLetter {
            if !seen.insert(char).inserted {
                return true
            }
        }
        return false
    }
}
