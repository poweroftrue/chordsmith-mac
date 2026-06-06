import Foundation

public enum MorphologyRelation: String, Codable, Hashable, Sendable {
    case lemma
    case plural
    case past
    case gerund
    case thirdPerson
    case comparative
    case superlative
    case ly
    case tion
    case ation
    case sion
    case ment
    case ness
    case ity
    case able
    case ible
    case ive
    case erOr
    case unPrefix

    var displayName: String {
        switch self {
        case .lemma: "lemma"
        case .plural: "plural"
        case .past: "past tense"
        case .gerund: "-ing"
        case .thirdPerson: "third-person"
        case .comparative: "comparative"
        case .superlative: "superlative"
        case .ly: "-ly"
        case .tion: "-tion"
        case .ation: "-ation"
        case .sion: "-sion"
        case .ment: "-ment"
        case .ness: "-ness"
        case .ity: "-ity"
        case .able: "-able"
        case .ible: "-ible"
        case .ive: "-ive"
        case .erOr: "-er/-or"
        case .unPrefix: "un-"
        }
    }
}

public struct MorphologyMatch: Codable, Hashable, Sendable {
    public let form: String
    public let lemma: String
    public let relation: MorphologyRelation
    public let suffixMarker: String?
    public let confidence: Double

    public init(
        form: String,
        lemma: String,
        relation: MorphologyRelation,
        suffixMarker: String?,
        confidence: Double
    ) {
        self.form = Self.normalize(form)
        self.lemma = Self.normalize(lemma)
        self.relation = relation
        self.suffixMarker = suffixMarker?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.confidence = confidence
    }

    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

public struct EnglishMorphologyIndex: Sendable {
    public static let bundled = EnglishMorphologyIndex(entries: Self.loadBundledEntries())

    private let entriesByForm: [String: [MorphologyMatch]]

    public init(entries: [MorphologyMatch] = []) {
        entriesByForm = Dictionary(grouping: entries, by: \.form)
    }

    public func matches(for word: String) -> [MorphologyMatch] {
        let normalized = MorphologyMatch.normalize(word)
        guard normalized.count >= 2 else { return [] }

        let direct = entriesByForm[normalized] ?? []
        let fallback = fallbackMatches(for: normalized)
        return Self.uniqueSorted(direct + fallback)
    }

    private static func loadBundledEntries() -> [MorphologyMatch] {
        guard let url = Bundle.module.url(forResource: "english_morphology", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return parseTSV(text)
    }

    private static func parseTSV(_ text: String) -> [MorphologyMatch] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> MorphologyMatch? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                let columns = trimmed.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard columns.count >= 5,
                      let relation = MorphologyRelation(rawValue: columns[2]),
                      let confidence = Double(columns[4]) else {
                    return nil
                }
                return MorphologyMatch(
                    form: columns[0],
                    lemma: columns[1],
                    relation: relation,
                    suffixMarker: columns[3].isEmpty ? nil : columns[3],
                    confidence: confidence
                )
            }
    }

    private static func uniqueSorted(_ matches: [MorphologyMatch]) -> [MorphologyMatch] {
        var bestByIdentity: [String: MorphologyMatch] = [:]
        for match in matches where match.form != match.lemma || match.relation != .lemma {
            let key = "\(match.lemma)\u{0}\(match.relation.rawValue)\u{0}\(match.suffixMarker ?? "")"
            if let existing = bestByIdentity[key], existing.confidence >= match.confidence {
                continue
            }
            bestByIdentity[key] = match
        }
        return bestByIdentity.values.sorted { lhs, rhs in
            if lhs.confidence == rhs.confidence {
                if lhs.lemma == rhs.lemma {
                    return lhs.relation.rawValue < rhs.relation.rawValue
                }
                return lhs.lemma < rhs.lemma
            }
            return lhs.confidence > rhs.confidence
        }
    }

    private func fallbackMatches(for word: String) -> [MorphologyMatch] {
        var matches: [MorphologyMatch] = []

        func add(_ lemma: String, _ relation: MorphologyRelation, _ marker: String, _ confidence: Double) {
            let normalizedLemma = MorphologyMatch.normalize(lemma)
            guard normalizedLemma.count >= 2, normalizedLemma != word else { return }
            matches.append(
                MorphologyMatch(
                    form: word,
                    lemma: normalizedLemma,
                    relation: relation,
                    suffixMarker: marker,
                    confidence: confidence
                )
            )
        }

        if word.hasPrefix("un"), word.count > 5 {
            add(String(word.dropFirst(2)), .unPrefix, "u", 0.84)
        }

        if word.hasSuffix("ies"), word.count > 4 {
            add(String(word.dropLast(3)) + "y", .plural, "s", 0.78)
            add(String(word.dropLast(3)) + "y", .thirdPerson, "s", 0.70)
        }
        if word.hasSuffix("es"), word.count > 4 {
            let base = String(word.dropLast(2))
            add(base, .plural, "s", 0.72)
            add(base, .thirdPerson, "s", 0.70)
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), word.count > 3 {
            let base = String(word.dropLast())
            add(base, .plural, "s", 0.66)
            add(base, .thirdPerson, "s", 0.64)
        }

        if word.hasSuffix("ied"), word.count > 4 {
            add(String(word.dropLast(3)) + "y", .past, "d", 0.78)
        }
        if word.hasSuffix("ed"), word.count > 4 {
            let base = String(word.dropLast(2))
            add(base, .past, "d", 0.72)
            add(base + "e", .past, "d", 0.76)
            if let undoubled = removeFinalDoubleConsonant(base) {
                add(undoubled, .past, "d", 0.74)
            }
        }

        if word.hasSuffix("ying"), word.count > 5 {
            add(String(word.dropLast(4)) + "y", .gerund, "g", 0.78)
        }
        if word.hasSuffix("ing"), word.count > 5 {
            let base = String(word.dropLast(3))
            add(base, .gerund, "g", 0.72)
            add(base + "e", .gerund, "g", 0.76)
            if let undoubled = removeFinalDoubleConsonant(base) {
                add(undoubled, .gerund, "g", 0.78)
            }
        }

        if word.hasSuffix("iest"), word.count > 5 {
            add(String(word.dropLast(4)) + "y", .superlative, "s", 0.76)
        }
        if word.hasSuffix("ier"), word.count > 4 {
            add(String(word.dropLast(3)) + "y", .comparative, "r", 0.76)
        }
        if word.hasSuffix("est"), word.count > 5 {
            let base = String(word.dropLast(3))
            add(base, .superlative, "s", 0.68)
            if let undoubled = removeFinalDoubleConsonant(base) {
                add(undoubled, .superlative, "s", 0.72)
            }
        }
        if word.hasSuffix("er"), word.count > 4 {
            let base = String(word.dropLast(2))
            add(base, .comparative, "r", 0.62)
            add(base, .erOr, "r", 0.62)
            if let undoubled = removeFinalDoubleConsonant(base) {
                add(undoubled, .comparative, "r", 0.70)
            }
        }
        if word.hasSuffix("or"), word.count > 4 {
            add(String(word.dropLast(2)), .erOr, "r", 0.62)
        }

        if word.hasSuffix("ily"), word.count > 4 {
            add(String(word.dropLast(3)) + "y", .ly, "l", 0.78)
        } else if word.hasSuffix("ly"), word.count > 4 {
            add(String(word.dropLast(2)), .ly, "l", 0.72)
        }

        if word.hasSuffix("ation"), word.count > 7 {
            let base = String(word.dropLast(5))
            add(base + "e", .ation, "t", 0.82)
            add(base, .ation, "t", 0.70)
        }
        if word.hasSuffix("tion"), word.count > 6 {
            let base = String(word.dropLast(4))
            add(base, .tion, "t", 0.66)
            add(base + "e", .tion, "t", 0.70)
        }
        if word.hasSuffix("sion"), word.count > 6 {
            let base = String(word.dropLast(4))
            add(base, .sion, "t", 0.66)
            add(base + "e", .sion, "t", 0.68)
        }
        if word.hasSuffix("ment"), word.count > 6 {
            let base = String(word.dropLast(4))
            add(base, .ment, "m", 0.70)
            add(base + "e", .ment, "m", 0.70)
        }
        if word.hasSuffix("ness"), word.count > 6 {
            let base = String(word.dropLast(4))
            add(base, .ness, "n", 0.70)
            if base.hasSuffix("i") {
                add(String(base.dropLast()) + "y", .ness, "n", 0.78)
            }
        }
        if word.hasSuffix("ity"), word.count > 5 {
            let base = String(word.dropLast(3))
            add(base, .ity, "y", 0.64)
            add(base + "e", .ity, "y", 0.68)
        }
        if word.hasSuffix("able"), word.count > 6 {
            let base = String(word.dropLast(4))
            add(base, .able, "b", 0.66)
            add(base + "e", .able, "b", 0.70)
        }
        if word.hasSuffix("ible"), word.count > 6 {
            let base = String(word.dropLast(4))
            add(base, .ible, "b", 0.66)
            add(base + "e", .ible, "b", 0.66)
        }
        if word.hasSuffix("ive"), word.count > 5 {
            let base = String(word.dropLast(3))
            add(base, .ive, "v", 0.70)
            add(base + "e", .ive, "v", 0.62)
        }

        return matches
    }

    private func removeFinalDoubleConsonant(_ value: String) -> String? {
        guard value.count >= 3,
              let last = value.last,
              !Self.vowels.contains(last) else {
            return nil
        }
        let previous = value.dropLast().last
        guard previous == last else { return nil }
        return String(value.dropLast())
    }

    private static let vowels = Set("aeiou")
}
