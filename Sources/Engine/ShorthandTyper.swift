import Foundation
import Library

/// The keystroke-level rules for laptop shorthand, separate from event taps
/// so they can be tested. Keys always go through on time; the typer only
/// asks to act:
///
/// - on a trigger key (Space or punctuation) after a shorthand's letters,
/// - when the last key of a mashed chord is released, the way CCOS does it:
///   the letters appear as you press, then become the word,
/// - on the backspace right after a replacement, to undo it.
public struct ShorthandTyper: Sendable {
    public enum Key: Equatable, Sendable {
        /// Text a key typed, with no Command, Control or Option held.
        case text(String, isRepeat: Bool, at: TimeInterval, keyCode: UInt16 = 0)
        case keyUp(keyCode: UInt16, at: TimeInterval)
        case backspace(isRepeat: Bool)
        /// Option+Backspace or Command+Backspace.
        case deleteWord
        /// Return, Tab, arrows, a click, a shortcut, an app switch: the
        /// cursor may be anywhere now.
        case boundary
    }

    public enum ReplacementKind: String, Sendable {
        /// Letters then Space or punctuation.
        case expand
        /// Keys mashed together; a space is added like the M4G does.
        case chord
        case undo
        /// Tidying after a chord: `about ` + `,` becomes `about, `.
        case edit
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
        /// Drop the key: a repeat while a chord is held, or the Space you
        /// add out of habit after a chord that already added one.
        case swallow
    }

    public struct Options: Equatable, Sendable {
        public var expandOnPunctuation = true
        public var undoWithBackspace = true
        public var mashChords = true

        public init(expandOnPunctuation: Bool = true, undoWithBackspace: Bool = true, mashChords: Bool = true) {
            self.expandOnPunctuation = expandOnPunctuation
            self.undoWithBackspace = undoWithBackspace
            self.mashChords = mashChords
        }
    }

    /// Timing of one mash, for tuning and the log.
    public struct ChordAttempt: Equatable, Sendable {
        public let keys: Int
        /// From the first key down to the last key down.
        public let spreadMs: Int
        /// How long every key was held down together.
        public let togetherMs: Int
        public let matched: Bool
        public let reason: String
    }

    /// Faster than any person types: this is a device or a tool typing.
    static let burstInterval: TimeInterval = 0.012
    static let punctuationTriggers: Set<Character> = [",", ".", ";", ":", "!", "?"]
    /// After these a new word starts, e.g. `(abt`.
    static let openers: Set<Character> = ["(", "[", "{", "\"", "“", "‘", "<", "¿", "¡"]

    /// How far apart the key presses of a chord may be. Rolling a word
    /// spreads presses over 60 ms or more per key; mashing is near-instant.
    static func maxSpread(keys: Int, isRealWord: Bool) -> TimeInterval {
        if isRealWord { return 0.03 }
        return keys <= 2 ? 0.045 : 0.045 + 0.015 * Double(keys - 2)
    }

    /// How long all keys must be down at once. Rolled typing lets go of a
    /// key soon after the next goes down; a chord is held.
    static func minTogether(spread: TimeInterval, isRealWord: Bool) -> TimeInterval {
        if isRealWord { return 0.06 }
        return max(0.03, spread * 0.5)
    }

    private struct ChordPress: Sendable {
        var down: Set<UInt16>
        var keyCodes: Set<UInt16>
        var characters: [Character]
        let firstPress: TimeInterval
        var lastPress: TimeInterval
        var firstRelease: TimeInterval?
        let startedAsWord: Bool
        var isValid = true
    }

    /// What was typed since the last cursor move, as it now reads on
    /// screen, so edits and undos keep track of where the word starts.
    private var line: [Character] = []
    private var times: [TimeInterval] = []
    /// Whether the start of `line` is the start of a word (after a click,
    /// Return, …). False once you backspace past it into unknown text.
    private var lineStartsWord = true
    private var lastReplacement: Replacement?
    private var press: ChordPress?
    /// Tokens undone in this session, never replaced again until restart.
    private var undoneThisSession: Set<String> = []
    private static let maxLine = 256

    public private(set) var lastChordAttempt: ChordAttempt?
    public private(set) var chordAttempts = 0

    public init() {}

    public var currentToken: String { String(token) }

    public mutating func reset() {
        line.removeAll(keepingCapacity: true)
        times.removeAll(keepingCapacity: true)
        lineStartsWord = true
        lastReplacement = nil
        press = nil
    }

    // MARK: Line model

    /// Letters, digits and apostrophes at the end of the line.
    private var tokenStart: Int {
        var index = line.count
        while index > 0, ShorthandLetters.isShorthandCharacter(line[index - 1]) { index -= 1 }
        return index
    }

    private var token: [Character] { Array(line[tokenStart...]) }

    private static func startsWordAfter(_ character: Character) -> Bool {
        character.isWhitespace || openers.contains(character)
    }

    /// Whether the token begins a word, and isn't the end of `gmail.com`.
    private var tokenIsWholeWord: Bool {
        let start = tokenStart
        return start > 0 ? Self.startsWordAfter(line[start - 1]) : lineStartsWord
    }

    /// Whether a letter typed now would start a word.
    private var atWordStart: Bool {
        guard let last = line.last else { return lineStartsWord }
        return Self.startsWordAfter(last)
    }

    private mutating func append<S: Sequence>(_ characters: S, at time: TimeInterval) where S.Element == Character {
        for character in characters {
            line.append(character)
            times.append(time)
        }
        if line.count > Self.maxLine {
            line.removeFirst(line.count - Self.maxLine)
            times.removeFirst(times.count - Self.maxLine)
            lineStartsWord = false
        }
    }

    private mutating func deleteBack(_ count: Int) {
        let removable = min(count, line.count)
        line.removeLast(removable)
        times.removeLast(removable)
        if count > removable { lineStartsWord = false }
    }

    private mutating func apply(_ replacement: Replacement) {
        deleteBack(replacement.deleteCount)
        // Typed by us: never a burst, never part of a new press.
        append(replacement.insert, at: -.infinity)
    }

    public mutating func handle(
        _ key: Key,
        options: Options = Options(),
        match: (String) -> ShorthandMatch?,
        chordMatch: ((String) -> ShorthandMatch?)? = nil,
        isRealWord: (String) -> Bool = { _ in false }
    ) -> Action {
        switch key {
        case .boundary, .deleteWord:
            reset()
            return .pass

        case .keyUp(let keyCode, let time):
            if let chordMatch {
                return release(keyCode, at: time, options: options, chordMatch: chordMatch, isRealWord: isRealWord)
            }
            return withoutActuallyEscaping(match) { match in
                release(keyCode, at: time, options: options, chordMatch: match, isRealWord: isRealWord)
            }

        case .backspace(let isRepeat):
            press?.isValid = false
            if let last = lastReplacement, last.kind == .expand || last.kind == .chord, options.undoWithBackspace, !isRepeat {
                return undo(last)
            }
            lastReplacement = nil
            deleteBack(1)
            return .pass

        case .text(let text, let isRepeat, let time, let keyCode):
            if isRepeat, let press, press.down.count >= 2 {
                // Holding a chord a little long must not type extra letters.
                return .swallow
            }
            if let last = lastReplacement, last.kind == .chord, !isRepeat, text.count == 1, let character = text.first {
                lastReplacement = nil
                if character == " " {
                    return .swallow
                }
                if Self.punctuationTriggers.contains(character) {
                    let edit = Replacement(
                        kind: .edit, deleteCount: 1, insert: "\(character) ", typed: "", output: "",
                        trigger: String(character), chordID: nil, savedKeystrokes: 0
                    )
                    apply(edit)
                    return .replace(edit)
                }
            }
            lastReplacement = nil
            guard !isRepeat, text.count == 1, let character = text.first else {
                // Held keys and pasted or injected strings still land on
                // screen; they just never start a press.
                press?.isValid = false
                append(text, at: -.infinity)
                return .pass
            }
            if ShorthandLetters.isShorthandCharacter(character) {
                notePress(keyCode, character: character, at: time, startsWord: token.isEmpty && atWordStart)
                append([character], at: time)
                return .pass
            }
            press?.isValid = false
            let isTrigger = character == " " ||
                (options.expandOnPunctuation && Self.punctuationTriggers.contains(character))
            let typed = String(token)
            guard isTrigger, !typed.isEmpty, tokenIsWholeWord, !isBurst,
                  !undoneThisSession.contains(typed.lowercased()), let found = match(typed) else {
                append([character], at: time)
                return .pass
            }
            let replacement = Replacement(
                kind: .expand,
                deleteCount: typed.count,
                insert: found.text + String(character),
                typed: typed,
                output: found.text,
                trigger: String(character),
                chordID: found.shorthand.chordID,
                savedKeystrokes: max(found.text.count - typed.count, 0)
            )
            apply(replacement)
            lastReplacement = replacement
            return .replace(replacement)
        }
    }

    // MARK: Mashed chords

    private mutating func notePress(_ keyCode: UInt16, character: Character, at time: TimeInterval, startsWord: Bool) {
        if var current = press {
            // A new key after one was let go, or the same key twice, is
            // typing, not a chord.
            if current.firstRelease != nil || current.keyCodes.contains(keyCode) { current.isValid = false }
            current.down.insert(keyCode)
            current.keyCodes.insert(keyCode)
            current.characters.append(character)
            current.lastPress = time
            press = current
        } else {
            press = ChordPress(
                down: [keyCode], keyCodes: [keyCode], characters: [character],
                firstPress: time, lastPress: time, startedAsWord: startsWord
            )
        }
    }

    private mutating func release(
        _ keyCode: UInt16,
        at time: TimeInterval,
        options: Options,
        chordMatch: (String) -> ShorthandMatch?,
        isRealWord: (String) -> Bool
    ) -> Action {
        guard var current = press, current.down.contains(keyCode) else { return .pass }
        current.down.remove(keyCode)
        if current.firstRelease == nil { current.firstRelease = time }
        guard current.down.isEmpty else {
            press = current
            return .pass
        }
        press = nil
        guard options.mashChords, current.characters.count >= 2, let firstRelease = current.firstRelease else { return .pass }

        let typed = String(current.characters)
        let spread = current.lastPress - current.firstPress
        let together = firstRelease - current.lastPress
        let realWord = isRealWord(typed.lowercased())
        func attempt(_ matched: Bool, _ reason: String) {
            chordAttempts += 1
            lastChordAttempt = ChordAttempt(
                keys: current.characters.count,
                spreadMs: Int((spread * 1_000).rounded()),
                togetherMs: Int((together * 1_000).rounded()),
                matched: matched,
                reason: reason
            )
        }
        // Only presses where every key was down at once are worth a look.
        guard current.isValid, together >= 0 else { return .pass }
        guard current.startedAsWord, token == current.characters, tokenIsWholeWord else {
            attempt(false, "not at a word start")
            return .pass
        }
        guard spread <= Self.maxSpread(keys: current.characters.count, isRealWord: realWord) else {
            attempt(false, "presses too far apart")
            return .pass
        }
        guard together >= Self.minTogether(spread: spread, isRealWord: realWord) else {
            attempt(false, "not held together long enough")
            return .pass
        }
        guard let found = chordMatch(typed) else {
            attempt(false, "no chord with these keys")
            return .pass
        }
        attempt(true, "chord")
        let replacement = Replacement(
            kind: .chord,
            deleteCount: token.count,
            insert: found.text + " ",
            typed: typed,
            output: found.text,
            trigger: " ",
            chordID: found.shorthand.chordID,
            savedKeystrokes: max(found.text.count + 1 - typed.count, 0)
        )
        apply(replacement)
        lastReplacement = replacement
        return .replace(replacement)
    }

    // MARK: Undo

    private mutating func undo(_ last: Replacement) -> Action {
        lastReplacement = nil
        press = nil
        // The restored letters stay as typed for this session, whether they
        // came from Space or from a press.
        undoneThisSession.insert(last.typed.lowercased())
        // A chord's space was the chord's, not yours.
        let trigger = last.kind == .chord ? "" : last.trigger
        let undo = Replacement(
            kind: .undo,
            deleteCount: last.insert.count,
            insert: last.typed + trigger,
            typed: last.typed,
            output: last.output,
            trigger: trigger,
            chordID: last.chordID,
            savedKeystrokes: 0
        )
        apply(undo)
        return .replace(undo)
    }

    private var isBurst: Bool {
        let tokenTimes = times[tokenStart...]
        guard tokenTimes.count >= 3, let first = tokenTimes.first, let last = tokenTimes.last,
              first.isFinite else { return false }
        return (last - first) / Double(tokenTimes.count - 1) < Self.burstInterval
    }
}
