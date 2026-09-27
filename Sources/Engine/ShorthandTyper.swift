import Foundation
import Library

/// The keystroke-level rules for laptop shorthand, separate from event taps
/// so they can be tested. It watches keys go by and only ever asks to act on
/// a trigger key (Space or punctuation) or on the backspace right after a
/// replacement. Every other key passes through untouched and on time.
public struct ShorthandTyper: Sendable {
    public enum Key: Equatable, Sendable {
        /// Text a key typed, with no Command, Control or Option held.
        case text(String, isRepeat: Bool, at: TimeInterval)
        case backspace(isRepeat: Bool)
        /// Option+Backspace or Command+Backspace.
        case deleteWord
        /// Return, Tab, arrows, a click, a shortcut, an app switch: the
        /// cursor may be anywhere now.
        case boundary
    }

    public enum ReplacementKind: String, Sendable {
        case expand
        case undo
    }

    public struct Replacement: Equatable, Sendable {
        public let kind: ReplacementKind
        /// Characters to delete before inserting.
        public let deleteCount: Int
        public let insert: String
        /// The letters as typed, e.g. `abt`.
        public let typed: String
        /// The text they became, e.g. `about`.
        public let output: String
        public let trigger: String
        public let chordID: UUID?
        public let savedKeystrokes: Int
    }

    public enum Action: Equatable, Sendable {
        case pass
        /// Swallow the key and replace text instead.
        case replace(Replacement)
    }

    public struct Options: Equatable, Sendable {
        public var expandOnPunctuation = true
        public var undoWithBackspace = true

        public init(expandOnPunctuation: Bool = true, undoWithBackspace: Bool = true) {
            self.expandOnPunctuation = expandOnPunctuation
            self.undoWithBackspace = undoWithBackspace
        }
    }

    /// Faster than any person types: this is a device or a tool typing.
    static let burstInterval: TimeInterval = 0.012
    static let punctuationTriggers: Set<Character> = [",", ".", ";", ":", "!", "?"]
    /// After these a new word starts, e.g. `(abt`.
    static let openers: Set<Character> = ["(", "[", "{", "\"", "“", "‘", "<", "¿", "¡"]

    private var token: [Character] = []
    private var tokenTimes: [TimeInterval] = []
    /// Whether the token started right after a space, a new line or a
    /// cursor move, so it is a whole word and not the end of `gmail.com`.
    private var tokenIsWholeWord = false
    private var atWordStart = true
    private var tokenIsTainted = false
    private var lastReplacement: Replacement?
    /// Tokens undone in this session, never replaced again until restart.
    private var undoneThisSession: Set<String> = []

    public init() {}

    public var currentToken: String { String(token) }

    public mutating func reset() {
        clearToken()
        atWordStart = true
        lastReplacement = nil
    }

    public mutating func handle(
        _ key: Key,
        options: Options = Options(),
        match: (String) -> ShorthandMatch?
    ) -> Action {
        switch key {
        case .boundary, .deleteWord:
            reset()
            return .pass

        case .backspace(let isRepeat):
            if let last = lastReplacement, last.kind == .expand, options.undoWithBackspace, !isRepeat {
                lastReplacement = nil
                clearToken()
                undoneThisSession.insert(last.typed.lowercased())
                atWordStart = last.trigger.first?.isWhitespace ?? false
                let undo = Replacement(
                    kind: .undo,
                    deleteCount: last.insert.count,
                    insert: last.typed + last.trigger,
                    typed: last.typed,
                    output: last.output,
                    trigger: last.trigger,
                    chordID: last.chordID,
                    savedKeystrokes: 0
                )
                return .replace(undo)
            }
            lastReplacement = nil
            if token.isEmpty {
                // Deleting into text written before: the cursor now sits at
                // the end of something unknown.
                atWordStart = false
                tokenIsWholeWord = false
            } else {
                token.removeLast()
                tokenTimes.removeLast()
                if token.isEmpty {
                    atWordStart = tokenIsWholeWord
                    tokenIsTainted = false
                }
            }
            return .pass

        case .text(let text, let isRepeat, let time):
            lastReplacement = nil
            guard !isRepeat, text.count == 1, let character = text.first else {
                // Held keys and pasted or injected strings: not a shorthand.
                if !token.isEmpty || isRepeat { tokenIsTainted = true }
                if text.count > 1 { clearToken(); atWordStart = false }
                return .pass
            }
            if ShorthandLetters.isShorthandCharacter(character) {
                if token.isEmpty {
                    tokenIsWholeWord = atWordStart
                    tokenIsTainted = false
                }
                token.append(character)
                tokenTimes.append(time)
                atWordStart = false
                return .pass
            }
            let isTrigger = character == " " ||
                (options.expandOnPunctuation && Self.punctuationTriggers.contains(character))
            defer {
                clearToken()
                atWordStart = character.isWhitespace || Self.openers.contains(character)
            }
            guard isTrigger, !token.isEmpty, tokenIsWholeWord, !tokenIsTainted, !isBurst else {
                return .pass
            }
            let typed = String(token)
            guard !undoneThisSession.contains(typed.lowercased()), let found = match(typed) else {
                return .pass
            }
            let replacement = Replacement(
                kind: .expand,
                deleteCount: token.count,
                insert: found.text + String(character),
                typed: typed,
                output: found.text,
                trigger: String(character),
                chordID: found.shorthand.chordID,
                savedKeystrokes: max(found.text.count - typed.count, 0)
            )
            lastReplacement = replacement
            return .replace(replacement)
        }
    }

    private mutating func clearToken() {
        token.removeAll(keepingCapacity: true)
        tokenTimes.removeAll(keepingCapacity: true)
        tokenIsWholeWord = false
        tokenIsTainted = false
    }

    private var isBurst: Bool {
        guard tokenTimes.count >= 3, let first = tokenTimes.first, let last = tokenTimes.last else { return false }
        return (last - first) / Double(tokenTimes.count - 1) < Self.burstInterval
    }
}
