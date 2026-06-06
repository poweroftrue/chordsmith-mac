import Foundation

struct WordAnchor: Hashable, Sendable {
    let token: String
    let weight: Double
    let reasons: [String]
    let isSuffixMarker: Bool
}

struct WordAnchorCoverage: Sendable {
    let tokens: [String]
    let weight: Double

    var scoreBonus: Double {
        weight * 0.8
    }
}

struct WordAnchorAnalysis: Sendable {
    let word: String
    let anchors: [WordAnchor]
    let suffixMarker: String?

    var orderedTokens: [String] {
        anchors.map(\.token)
    }

    func strongestTokens(limit: Int) -> [String] {
        Array(orderedTokens.prefix(max(limit, 0)))
    }

    func weight(for token: String) -> Double {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return anchors.first { $0.token == normalized }?.weight ?? 0
    }

    func coverage(for tokens: [String]) -> WordAnchorCoverage {
        let tokenSet = Set(tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let covered = anchors.filter { tokenSet.contains($0.token) }
        return WordAnchorCoverage(
            tokens: covered.map(\.token),
            weight: covered.reduce(0) { $0 + $1.weight }
        )
    }
}

struct WordAnchorAnalyzer: Sendable {
    func analysis(for word: String) -> WordAnchorAnalysis {
        let letters = Self.asciiLetterTokens(from: word)
        guard !letters.isEmpty else {
            return WordAnchorAnalysis(word: "", anchors: [], suffixMarker: nil)
        }

        let normalizedWord = letters.joined()
        let suffixMarker = Self.suffixMarker(for: normalizedWord)
        let stemLetters = Self.asciiLetterTokens(from: Self.stemCandidate(for: normalizedWord))
        let stemConsonants = Self.uniqueTokens(stemLetters.filter { !Self.vowels.contains($0) })
        let counts = Dictionary(letters.map { ($0, 1) }, uniquingKeysWith: +)
        let uniqueLetters = Self.uniqueTokens(letters)

        let anchors = uniqueLetters.enumerated().map { index, token in
            buildAnchor(
                token: token,
                wordIndex: index,
                count: counts[token] ?? 1,
                suffixMarker: suffixMarker,
                stemConsonants: stemConsonants
            )
        }
        .sorted { lhs, rhs in
            if lhs.weight == rhs.weight {
                let lhsIndex = uniqueLetters.firstIndex(of: lhs.token) ?? Int.max
                let rhsIndex = uniqueLetters.firstIndex(of: rhs.token) ?? Int.max
                if lhsIndex == rhsIndex {
                    return lhs.token < rhs.token
                }
                return lhsIndex < rhsIndex
            }
            return lhs.weight > rhs.weight
        }

        return WordAnchorAnalysis(
            word: normalizedWord,
            anchors: anchors,
            suffixMarker: suffixMarker
        )
    }

    private func buildAnchor(
        token: String,
        wordIndex: Int,
        count: Int,
        suffixMarker: String?,
        stemConsonants: [String]
    ) -> WordAnchor {
        let isVowel = Self.vowels.contains(token)
        var weight = isVowel ? 2.0 : 8.0
        var reasons = [isVowel ? "vowel" : "consonant"]

        if wordIndex == 0 {
            weight += 2.0
            reasons.append("word start")
        }

        if let rareBonus = Self.distinctiveLetterBonus[token] {
            weight += rareBonus
            reasons.append("distinctive letter")
        }

        if let stemIndex = stemConsonants.firstIndex(of: token) {
            switch stemIndex {
            case 0:
                weight += 3.0
            case 1:
                weight += 6.0
            case 2:
                weight += 3.0
            default:
                weight += 1.5
            }
            if stemIndex == stemConsonants.count - 1 {
                weight += 1.5
            }
            reasons.append("stem anchor")
        }

        let isSuffixMarker = suffixMarker == token
        if isSuffixMarker {
            weight += 10.0
            reasons.append("suffix marker")
        }

        if count > 1 {
            weight -= Double(count - 1) * (isVowel ? 1.5 : 0.75)
        }

        return WordAnchor(
            token: token,
            weight: max(weight, 0),
            reasons: reasons,
            isSuffixMarker: isSuffixMarker
        )
    }

    private static func asciiLetterTokens(from value: String) -> [String] {
        value.unicodeScalars.compactMap { scalar in
            switch scalar.value {
            case 65...90:
                return String(UnicodeScalar(scalar.value + 32)!)
            case 97...122:
                return String(scalar)
            default:
                return nil
            }
        }
    }

    private static func uniqueTokens(_ tokens: [String]) -> [String] {
        tokens.reduce(into: [String]()) { result, token in
            if !result.contains(token) {
                result.append(token)
            }
        }
    }

    private static func stemCandidate(for word: String) -> String {
        for suffix in stemSuffixes where word.hasSuffix(suffix.text) && word.count > suffix.minimumWordLength {
            return String(word.dropLast(suffix.text.count))
        }
        return word
    }

    private static func suffixMarker(for word: String) -> String? {
        for suffix in suffixMarkers where word.hasSuffix(suffix.text) && word.count > suffix.minimumWordLength {
            return suffix.marker
        }
        return nil
    }

    private static let vowels = Set(["a", "e", "i", "o", "u"])

    private static let distinctiveLetterBonus: [String: Double] = [
        "q": 10.0,
        "z": 9.0,
        "x": 8.5,
        "j": 8.0,
        "v": 7.5,
        "k": 5.5,
        "w": 4.0,
        "y": 3.0,
        "p": 2.5,
        "b": 2.0,
        "f": 2.0
    ]

    private static let suffixMarkers: [(text: String, marker: String, minimumWordLength: Int)] = [
        ("ation", "t", 7),
        ("tion", "t", 6),
        ("sion", "t", 6),
        ("ment", "m", 6),
        ("ness", "n", 6),
        ("able", "b", 6),
        ("ible", "b", 6),
        ("ity", "y", 5),
        ("ive", "v", 5),
        ("ly", "l", 4),
        ("ing", "g", 5),
        ("ed", "d", 4),
        ("es", "s", 4),
        ("s", "s", 3)
    ]

    private static let stemSuffixes: [(text: String, minimumWordLength: Int)] = [
        ("ation", 7),
        ("tion", 6),
        ("sion", 6),
        ("ment", 6),
        ("ness", 6),
        ("able", 6),
        ("ible", 6),
        ("ity", 5),
        ("ive", 5),
        ("ly", 4),
        ("ing", 5),
        ("ed", 4),
        ("es", 4),
        ("s", 3)
    ]
}
