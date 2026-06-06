import Foundation
import Library

enum ChordSearch {
    private static let ignoredTerms = Set(["chord", "chords", "m4g"])

    static func ranked(_ chords: [ChordEntry], query: String, limit: Int? = nil) -> [ChordEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return limit.map { Array(chords.prefix($0)) } ?? chords
        }

        let terms = searchTerms(from: trimmed)
        guard !terms.isEmpty else { return [] }

        let rankedChords = chords
            .compactMap { chord -> (chord: ChordEntry, score: Int)? in
                guard terms.allSatisfy({ matches(chord, term: $0) }) else { return nil }
                return (chord, score(chord, terms: terms))
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    if lhs.chord.output == rhs.chord.output {
                        return lhs.chord.normalizedInput < rhs.chord.normalizedInput
                    }
                    return lhs.chord.output < rhs.chord.output
                }
                return lhs.score > rhs.score
            }
            .map(\.chord)

        return limit.map { Array(rankedChords.prefix($0)) } ?? rankedChords
    }

    private static func searchTerms(from text: String) -> [String] {
        text
            .lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !ignoredTerms.contains($0) }
    }

    private static func matches(_ chord: ChordEntry, term: String) -> Bool {
        if chord.searchText.contains(term) {
            return true
        }
        if let compactInput = compactInputIdentity(for: term),
           inputIdentities(for: chord).contains(where: { $0.contains(compactInput) }) {
            return true
        }
        return compactInputText(for: chord).contains(term)
    }

    private static func score(_ chord: ChordEntry, terms: [String]) -> Int {
        let output = chord.output.lowercased()
        let plainOutput = (chord.plainOutput ?? "").lowercased()
        let inputIdentities = inputIdentities(for: chord)
        let compactDisplay = compactInputText(for: chord)
        var score = 0

        for term in terms {
            let compactInput = compactInputIdentity(for: term)

            if output == term || plainOutput == term {
                score += 1_000
            } else if output.hasPrefix(term) || plainOutput.hasPrefix(term) {
                score += 450
            } else if output.contains(term) || plainOutput.contains(term) {
                score += 80
            }

            if let compactInput {
                if inputIdentities.contains(compactInput) {
                    score += 950
                } else if inputIdentities.contains(where: { $0.contains(compactInput) }) {
                    score += 300
                }
            }

            if compactDisplay == term {
                score += 850
            } else if compactDisplay.contains(term) {
                score += 250
            }

            if chord.searchText.contains(term) {
                score += 20
            }
        }

        if chord.enabled {
            score += 5
        }
        return score
    }

    private static func inputIdentities(for chord: ChordEntry) -> [String] {
        var identities = [chord.normalizedInput]
        let displayInput = chord.displayInput.isEmpty ? chord.inputKeys : chord.displayInput
        let normalizedDisplay = ChordEntry.normalizeInputKeys(displayInput)
        if normalizedDisplay != chord.normalizedInput {
            identities.append(normalizedDisplay)
        }
        return identities
    }

    private static func compactInputText(for chord: ChordEntry) -> String {
        let displayInput = chord.displayInput.isEmpty ? chord.inputKeys : chord.displayInput
        return displayInput
            .map { ChordInputValidator.displayToken($0).lowercased() }
            .joined()
    }

    private static func compactInputIdentity(for term: String) -> String? {
        let tokens = ChordInputValidator.tokens(from: term, compactRepeatsUseDup: true)
        guard !tokens.isEmpty else { return nil }
        return ChordEntry.normalizeInputKeys(tokens)
    }
}
