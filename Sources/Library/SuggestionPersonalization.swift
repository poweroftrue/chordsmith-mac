import Foundation

// What the advisor learns from your own chord library, so suggestions look
// like chords you would have picked yourself.

/// Habits across every chord you made for a word: whether you include the
/// first and last letters, keep to letters of the word, and how many keys
/// you use for a word of a given length.
struct LibraryStyleModel: Sendable {
    /// Needs this many word chords before it trusts what it sees.
    static let minimumSample = 30

    let sampleSize: Int
    /// Share of chords that include the word's first letter.
    let firstLetterRate: Double
    let lastLetterRate: Double
    /// Share of chords whose letter keys all appear in the word.
    let inWordRate: Double
    /// Share of chords with a marker symbol such as `/` or `,`.
    let markerRate: Double
    static let markerTokens: Set<String> = [".", "'", "`", ",", ";", "/"]
    /// Average key count by word length (capped at 12).
    private let typicalLength: [Int: Double]

    var isTrained: Bool { sampleSize >= Self.minimumSample }

    /// How much a chord says about your habits: chords for words you write
    /// count by how often you write them; chords you never use barely count.
    static func weight(uses: Int?) -> Double {
        guard let uses else { return 1 }
        return uses > 0 ? 1 + log2(1 + Double(uses)) : 0.1
    }

    init(existingChords: [ChordEntry], uses: [String: Int]? = nil) {
        var sample = 0
        var totalWeight = 0.0
        var first = 0.0
        var last = 0.0
        var inWord = 0.0
        var markers = 0.0
        var lengthTotals: [Int: (sum: Double, count: Double)] = [:]
        for chord in existingChords {
            let word = (chord.plainOutput ?? chord.output).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard word.count >= 3, word.allSatisfy(\.isLetter) else { continue }
            let keys = chord.inputKeys.map { $0.lowercased() }
            guard !keys.isEmpty else { continue }
            let weight = Self.weight(uses: uses.map { $0[word] ?? 0 })
            sample += 1
            totalWeight += weight
            if let head = word.first, keys.contains(String(head)) { first += weight }
            if let tail = word.last, keys.contains(String(tail)) { last += weight }
            let letterKeys = keys.filter { $0.count == 1 && $0.first!.isLetter }
            if letterKeys.allSatisfy({ word.contains($0) }) { inWord += weight }
            if keys.contains(where: Self.markerTokens.contains) { markers += weight }
            let bucket = min(word.count, 12)
            let current = lengthTotals[bucket] ?? (0, 0)
            lengthTotals[bucket] = (current.sum + Double(keys.count) * weight, current.count + weight)
        }
        sampleSize = sample
        firstLetterRate = totalWeight > 0 ? first / totalWeight : 0
        lastLetterRate = totalWeight > 0 ? last / totalWeight : 0
        inWordRate = totalWeight > 0 ? inWord / totalWeight : 0
        markerRate = totalWeight > 0 ? markers / totalWeight : 0
        typicalLength = lengthTotals.mapValues { $0.sum / max($0.count, 0.001) }
    }

    /// The number of keys you usually give a word this long.
    func typicalKeys(forWordLength length: Int) -> Double? {
        let bucket = min(length, 12)
        if let value = typicalLength[bucket] { return value }
        let nearby = typicalLength.min { abs($0.key - bucket) < abs($1.key - bucket) }
        return nearby?.value
    }

    /// Bonus or penalty for how well `keys` fit your habits, with the
    /// strongest reason in plain words.
    func score(keys: [String], word: String, initials: [String]) -> (score: Double, reasons: [String]) {
        guard isTrained else { return (0, []) }
        var score = 0.0
        var reasons: [String] = []
        let percent = Int((firstLetterRate * 100).rounded())

        if initials.count > 1 {
            // A phrase: every word's first letter.
            let covered = initials.filter(keys.contains).count
            if covered == initials.count {
                score += 12
                reasons.append("Starts every word's first letter, like a phrase chord should.")
            } else {
                score -= Double(initials.count - covered) * 8
            }
        } else if let first = initials.first {
            if keys.contains(first) {
                score += 12 * firstLetterRate
                if firstLetterRate >= 0.7 {
                    reasons.append("Includes the first letter, like \(percent)% of your chords.")
                }
            } else {
                score -= 14 * firstLetterRate
                if firstLetterRate >= 0.7 {
                    reasons.append("Leaves out the first letter, unlike \(percent)% of your chords.")
                }
            }
        }

        if let last = word.last.map(String.init), last != initials.first, keys.contains(last) {
            score += 4 * lastLetterRate
        }

        let letters = Set(word)
        let foreign = keys.filter { $0.count == 1 && $0.first!.isLetter && !letters.contains($0.first!) }.count
        score -= Double(foreign) * 6 * inWordRate

        if let typical = typicalKeys(forWordLength: word.filter(\.isLetter).count) {
            score -= abs(Double(keys.count) - typical) * 4
        }
        return (score, reasons)
    }
}

/// Endings you already mark with a key: pairs in your library such as
/// `deploy` and `deployment`, where the longer word's chord is the shorter
/// word's chord plus one key.
struct FamilyMarkerModel: Sendable {
    struct Extension: Sendable {
        let base: String
        let baseKeys: [String]
        let suffix: String
        /// Marker keys to try, best first, and whether you used each before.
        let markers: [(key: String, learned: Bool)]
    }

    private let chordsByWord: [String: [String]]
    /// Suffix to the keys you added for it, with counts.
    let markersBySuffix: [String: [String: Int]]

    init(existingChords: [ChordEntry]) {
        var chordsByWord: [String: [String]] = [:]
        for chord in existingChords {
            let word = (chord.plainOutput ?? chord.output).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard word.count >= 2, word.allSatisfy(\.isLetter) else { continue }
            let keys = (chord.displayInput.isEmpty ? chord.inputKeys : chord.displayInput).map { $0.lowercased() }
            if let existing = chordsByWord[word], existing.count <= keys.count { continue }
            chordsByWord[word] = keys
        }
        var markers: [String: [String: Int]] = [:]
        for (word, keys) in chordsByWord where word.count >= 4 {
            let keySet = Set(keys)
            for length in stride(from: word.count - 1, through: 3, by: -1) {
                let prefix = String(word.prefix(length))
                for base in [prefix, prefix + "e"] where base != word {
                    guard let baseKeys = chordsByWord[base] else { continue }
                    let baseSet = Set(baseKeys)
                    let added = keySet.subtracting(baseSet)
                    guard baseSet.isSubset(of: keySet), added.count == 1, let key = added.first else { continue }
                    let suffix = String(word.dropFirst(length))
                    markers[suffix, default: [:]][key, default: 0] += 1
                }
            }
        }
        self.chordsByWord = chordsByWord
        self.markersBySuffix = markers
    }

    /// The longest chorded word that `word` starts with, and keys to add.
    func extensions(for word: String) -> [Extension] {
        guard word.count >= 5, word.allSatisfy(\.isLetter) else { return [] }
        var results: [Extension] = []
        for length in stride(from: word.count - 1, through: 4, by: -1) {
            let prefix = String(word.prefix(length))
            let suffix = String(word.dropFirst(length))
            // A short stem with a long tail is a different word (fun, function).
            guard suffix.count <= min(length, 6) else { break }
            for base in [prefix, prefix + "e"] where base != word {
                guard let baseKeys = chordsByWord[base], baseKeys.count <= 5 else { continue }
                let learned = (markersBySuffix[suffix] ?? [:])
                    .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    .map(\.key)
                    .filter { !baseKeys.contains($0) }
                // Otherwise a letter of the ending: its first consonant,
                // its last letter, then the rest.
                let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
                var generic: [String] = []
                if let consonant = suffix.first(where: { !vowels.contains($0) }) { generic.append(String(consonant)) }
                if let last = suffix.last { generic.append(String(last)) }
                generic += suffix.map(String.init)
                var seen = Set(learned)
                let fallback = generic.filter { !baseKeys.contains($0) && seen.insert($0).inserted }
                let markers = learned.prefix(3).map { ($0, true) } + fallback.prefix(4).map { ($0, false) }
                if !markers.isEmpty {
                    results.append(Extension(base: base, baseKeys: baseKeys, suffix: suffix, markers: markers))
                }
            }
            // The longest base is the closest relative; one more for choice.
            if results.count >= 2 { break }
        }
        return results
    }
}

/// Chords one key away from a candidate. A partial press of the bigger chord
/// types the smaller one, the most common kind of misfire.
struct ChordNeighborIndex: Sendable {
    private let outputsByKeySet: [Set<String>: String]
    private let setsBySize: [Int: [Set<String>]]

    init(existingChords: [ChordEntry]) {
        var outputs: [Set<String>: String] = [:]
        var bySize: [Int: [Set<String>]] = [:]
        for chord in existingChords {
            let keys = Set(chord.inputKeys.map { $0.lowercased() })
            guard keys.count >= 2, outputs[keys] == nil else { continue }
            outputs[keys] = (chord.plainOutput ?? chord.output).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            bySize[keys.count, default: []].append(keys)
        }
        outputsByKeySet = outputs
        setsBySize = bySize
    }

    /// Outputs of chords that are this chord with one key more or less,
    /// leaving out relatives of `word` (the same stem is intended).
    func neighbors(of keys: [String], word: String) -> [String] {
        let set = Set(keys)
        var found: [String] = []
        if set.count >= 3 {
            for key in set {
                if let output = outputsByKeySet[set.subtracting([key])] { found.append(output) }
            }
        }
        for bigger in setsBySize[set.count + 1] ?? [] where set.isSubset(of: bigger) {
            if let output = outputsByKeySet[bigger] { found.append(output) }
        }
        let stem = String(word.prefix(4))
        return found.filter { !($0.hasPrefix(stem) || word.hasPrefix(String($0.prefix(4)))) }
    }
}
