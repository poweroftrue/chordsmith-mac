import Foundation
import NaturalLanguage

public enum WordLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case arabic
    case english
    case mixed
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .arabic:
            return "Arabic"
        case .english:
            return "English"
        case .mixed:
            return "Mixed"
        case .other:
            return "Other"
        }
    }
}

public struct ProcessedWord: Equatable, Sendable {
    public let text: String
    public let language: WordLanguage

    public init(text: String, language: WordLanguage) {
        self.text = text
        self.language = language
    }
}

/// A small, local text pipeline shared by recording, persistence, and chord
/// coverage. Natural Language supplies Unicode-aware word boundaries while the
/// deterministic normalization keeps the hot path predictable and private.
public enum MultilingualWordProcessor {
    private static let wordJoiners = CharacterSet(charactersIn: "'\u{2019}\u{2010}\u{2011}-")

    public static func words(in text: String) -> [ProcessedWord] {
        let canonicalText = text.precomposedStringWithCanonicalMapping
        guard !canonicalText.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = canonicalText
        return tokenizer
            .tokens(for: canonicalText.startIndex..<canonicalText.endIndex)
            .compactMap { normalize(String(canonicalText[$0])) }
    }

    public static func normalize(_ token: String) -> ProcessedWord? {
        var candidate = token
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")

        let containsArabic = candidate.unicodeScalars.contains(where: isArabic)
        if containsArabic {
            candidate = String(candidate.unicodeScalars.filter { scalar in
                scalar.value != 0x0640 && !isCombiningMark(scalar)
            })
        }

        candidate = candidate.trimmingCharacters(in: wordJoiners)
        guard !candidate.isEmpty,
              candidate.unicodeScalars.contains(where: isLetter) else {
            return nil
        }

        return ProcessedWord(
            text: candidate.precomposedStringWithCanonicalMapping,
            language: language(of: candidate)
        )
    }

    public static func language(of text: String) -> WordLanguage {
        var hasArabic = false
        var hasLatin = false
        var hasOtherLetter = false

        for scalar in text.unicodeScalars where isLetter(scalar) {
            if isArabic(scalar) {
                hasArabic = true
            } else if isLatin(scalar) {
                hasLatin = true
            } else {
                hasOtherLetter = true
            }
        }

        if hasArabic && !hasLatin && !hasOtherLetter { return .arabic }
        if hasLatin && !hasArabic && !hasOtherLetter { return .english }
        if [hasArabic, hasLatin, hasOtherLetter].filter({ $0 }).count > 1 { return .mixed }
        return .other
    }

    public static func isCoreWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            isLetter(scalar) || isCombiningMark(scalar)
        }
    }

    public static func isWordJoiner(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { wordJoiners.contains($0) }
    }

    private static func isLetter(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    private static func isCombiningMark(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    private static func isArabic(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x06FF,
             0x0750...0x077F,
             0x0870...0x089F,
             0x08A0...0x08FF,
             0xFB50...0xFDFF,
             0xFE70...0xFEFF,
             0x1EE00...0x1EEFF:
            return true
        default:
            return false
        }
    }

    private static func isLatin(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A,
             0x0061...0x007A,
             0x00C0...0x024F,
             0x1D00...0x1D7F,
             0x1D80...0x1DBF,
             0x1E00...0x1EFF,
             0xAB30...0xAB6F:
            return true
        default:
            return false
        }
    }
}
