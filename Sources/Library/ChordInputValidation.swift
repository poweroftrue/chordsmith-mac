import Foundation

public struct ChordInputValidation: Hashable, Sendable {
    public let tokens: [String]
    public let rawInputActions: [Int]?
    public let encodedInput: String?
    public let conflictingChordID: UUID?
    public let errors: [String]

    public var isValid: Bool {
        errors.isEmpty
    }

    public init(
        tokens: [String],
        rawInputActions: [Int]?,
        encodedInput: String?,
        conflictingChordID: UUID?,
        errors: [String]
    ) {
        self.tokens = tokens
        self.rawInputActions = rawInputActions
        self.encodedInput = encodedInput
        self.conflictingChordID = conflictingChordID
        self.errors = errors
    }
}

public enum ChordInputValidator {
    public static func tokens(from text: String, compactRepeatsUseDup: Bool = false) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let hasSeparator = trimmed.contains("+")
            || trimmed.contains(",")
            || trimmed.contains(" ")
            || trimmed.contains("\t")
            || trimmed.contains("\n")

        if hasSeparator {
            let separators = CharacterSet(charactersIn: "+, \t\n")
            return trimmed
                .components(separatedBy: separators)
                .map(normalizedToken)
                .filter { !$0.isEmpty }
        }

        let normalized = normalizedToken(trimmed)
        if normalized == "dup" {
            return ["dup"]
        }

        if let compactTokens = compactM4GCharacterTokens(from: normalized) {
            if compactRepeatsUseDup {
                return tokensReplacingCompactRepeatsWithDup(compactTokens)
            }
            return compactTokens
        }

        return [normalized]
    }

    public static func displayToken(_ token: String) -> String {
        let normalized = normalizedToken(token)
        if normalized == "dup" {
            return "DUP"
        }
        return normalized
    }

    public static func validateM4GDeviceInput(
        _ text: String,
        existingChords: [ChordEntry],
        replacingChordID: UUID? = nil,
        compactRepeatsUseDup: Bool = false
    ) -> ChordInputValidation {
        validateM4GDeviceTokens(
            tokens(from: text, compactRepeatsUseDup: compactRepeatsUseDup),
            existingChords: existingChords,
            replacingChordID: replacingChordID
        )
    }

    public static func validateM4GDeviceTokens(
        _ inputTokens: [String],
        existingChords: [ChordEntry],
        replacingChordID: UUID? = nil
    ) -> ChordInputValidation {
        let tokens = inputTokens.map(normalizedToken).filter { !$0.isEmpty }
        var errors: [String] = []
        var conflictingChordID: UUID?

        if tokens.isEmpty {
            errors.append("Chord input cannot be empty.")
        }

        if Set(tokens).count != tokens.count {
            errors.append("Duplicate physical key in chord input.")
        }

        let rawInputActions = ActionCodec.chordActions(forTokens: tokens)
        let encodedInput = rawInputActions.map(ActionCodec.stringifyChordActions)
        if rawInputActions == nil, !tokens.isEmpty {
            errors.append("Unsupported M4G action in chord input.")
        }

        let physicalModel = M4GPhysicalModel.defaultA1
        for token in tokens where physicalModel.bestPlacement(for: token) == nil {
            errors.append("Unsupported M4G physical action: \(token).")
        }
        errors.append(contentsOf: physicalModel.hardConflictReasons(for: tokens))

        if let encodedInput {
            let conflicts = existingChords
                .filter(isDeviceChord)
                .filter { $0.id != replacingChordID }
                .filter { chord in
                    if let chordEncoded = chord.encodedInput {
                        return chordEncoded.uppercased() == encodedInput.uppercased()
                    }
                    if let actions = chord.rawInputActions {
                        return ActionCodec.stringifyChordActions(actions).uppercased() == encodedInput.uppercased()
                    }
                    return ActionCodec.chordActions(forTokens: chord.inputKeys)
                        .map(ActionCodec.stringifyChordActions)?
                        .uppercased() == encodedInput.uppercased()
                }

            if let conflict = conflicts.first {
                conflictingChordID = conflict.id
                errors.append("Raw chord input already exists.")
            }
        }

        var seenErrors: Set<String> = []
        let uniqueErrors = errors.filter { seenErrors.insert($0).inserted }

        return ChordInputValidation(
            tokens: tokens,
            rawInputActions: rawInputActions,
            encodedInput: encodedInput,
            conflictingChordID: conflictingChordID,
            errors: uniqueErrors
        )
    }

    private static func normalizedToken(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func compactM4GCharacterTokens(from text: String) -> [String]? {
        let tokens = text.map { String($0) }
        guard tokens.count > 1,
              tokens.allSatisfy({ M4GPhysicalModel.defaultA1.bestPlacement(for: $0) != nil }) else {
            return nil
        }
        return tokens
    }

    private static func tokensReplacingCompactRepeatsWithDup(_ tokens: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for token in tokens {
            if seen.contains(token) {
                output.append("dup")
            } else {
                seen.insert(token)
                output.append(token)
            }
        }
        return output
    }

    private static func isDeviceChord(_ chord: ChordEntry) -> Bool {
        chord.profile == .cc2A1
            && (chord.deploymentTarget == .device || chord.deploymentTarget == .both)
    }
}
