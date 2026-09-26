import Foundation
import Library

public typealias TypingRecorder = UsageRecorder

/// One word as the recorder stored it, for live coaching.
public struct RecordedWord: Sendable {
    public let word: String
    public let source: UsageSource
    public let avgMs: Double
    public let language: WordLanguage
    /// Milliseconds from the end of the previous word, when typing was
    /// continuous; nil after a pause.
    public let cycleMs: Double?

    public init(word: String, source: UsageSource, avgMs: Double, language: WordLanguage, cycleMs: Double? = nil) {
        self.word = word
        self.source = source
        self.avgMs = avgMs
        self.language = language
        self.cycleMs = cycleMs
    }
}

public actor UsageRecorder {
    private struct BufferedCharacter {
        let character: Character
        let timestamp: Date
        let source: PhysicalInputSource
    }

    /// The last finished word, held back until the next word starts so that
    /// deleting its trailing delimiter can reopen it. CCOS suffix modifiers do
    /// exactly this (`go ` + backspace + `ing `), and so do quick typo fixes.
    private struct PendingWord {
        let characters: [BufferedCharacter]
        let endedAt: Date
        var trailingDelimiters: Int
        /// Exactly what was typed after the word. A single space means the
        /// next word continues the same phrase.
        var delimiters = ""
    }

    private let libraryService: LibraryService
    private var buffer: [BufferedCharacter] = []
    private var pendingWord: PendingWord?
    private var deviceChordsByOutput: [String: [ChordEntry]] = [:]
    private var idleFlushTask: Task<Void, Never>?
    /// Counts for the correction rate, written at word boundaries.
    private var pendingKeystrokes = 0
    private var pendingBackspaces = 0
    /// The last few words written with single spaces between them.
    private var phraseRun: [(word: String, handTyped: Bool)] = []
    private var previousWordJoinsNext = false
    private var wordObserver: (@Sendable (RecordedWord) -> Void)?
    /// When the previous word ended, for words-per-minute.
    private var lastWordEndedAt: Date?
    /// Longer gaps are pauses, not typing speed.
    private let speedPauseLimit: TimeInterval = 3
    /// What the buffer held when backspacing began, to spot a chord that was
    /// deleted outright.
    private var deletionStart: [BufferedCharacter]?
    private var pendingMisfires: [(word: String, at: Date)] = []
    /// Assumed connected until the HID monitor says otherwise, so words are
    /// never marked "away" by mistake.
    private var m4gConnected = true

    private let newWordThreshold: TimeInterval = 5.0
    /// Upper bound for the gap between characters of one chord output.
    private let chordBurstInterval: TimeInterval = 0.02

    public init(libraryService: LibraryService) {
        self.libraryService = libraryService
    }

    public func setM4GConnected(_ connected: Bool) {
        m4gConnected = connected
    }

    public func setWordObserver(_ observer: (@Sendable (RecordedWord) -> Void)?) {
        wordObserver = observer
    }

    public func updateDeviceChords(_ chords: [ChordEntry]) {
        deviceChordsByOutput = Dictionary(grouping: chords.compactMap { chord -> ChordEntry? in
            guard chord.enabled,
                  chord.profile == .cc2A1,
                  chord.deploymentTarget == .device || chord.deploymentTarget == .both,
                  let plainOutput = chord.plainOutput,
                  MultilingualWordProcessor.words(in: plainOutput).count == 1 else {
                return nil
            }
            return chord
        }) { chord in
            MultilingualWordProcessor.words(in: chord.plainOutput ?? chord.output)[0].text
        }
    }

    public func observeKeyboardText(
        _ text: String,
        source: PhysicalInputSource = .keyboard,
        startedAt: Date,
        endedAt: Date
    ) async {
        guard !text.isEmpty else { return }
        let characters = Array(text)
        pendingKeystrokes += characters.count
        let step = endedAt.timeIntervalSince(startedAt) / Double(max(characters.count, 1))

        for (index, character) in characters.enumerated() {
            let timestamp = startedAt.addingTimeInterval(step * Double(index))
            let continuesWord = MultilingualWordProcessor.isCoreWordCharacter(character) ||
                (MultilingualWordProcessor.isWordJoiner(character) && !buffer.isEmpty)
            if continuesWord {
                if let last = buffer.last,
                   timestamp.timeIntervalSince(last.timestamp) > newWordThreshold {
                    await finishWord(endedAt: last.timestamp)
                }
                if buffer.isEmpty {
                    await commitPendingWord(nextWordStarted: true)
                }
                deletionStart = nil
                // The device replacing its own output (a modifier turning
                // `run` into `ran`) deletes and retypes within milliseconds.
                if source == .m4g, let last = pendingMisfires.last,
                   abs(timestamp.timeIntervalSince(last.at)) < 0.15 {
                    pendingMisfires.removeLast()
                }
                buffer.append(
                    BufferedCharacter(
                        character: character,
                        timestamp: timestamp,
                        source: source
                    )
                )
            } else if !buffer.isEmpty {
                await finishWord(endedAt: timestamp)
                pendingWord?.trailingDelimiters += 1
                pendingWord?.delimiters.append(character)
            } else if pendingWord != nil {
                pendingWord?.trailingDelimiters += 1
                pendingWord?.delimiters.append(character)
            }
            scheduleIdleFlush()
        }
    }

    public func observeBackspace() {
        pendingBackspaces += 1
        if !buffer.isEmpty {
            if deletionStart == nil {
                deletionStart = buffer
            }
            buffer.removeLast()
            if buffer.isEmpty {
                noteDeletedChord()
            }
        } else if var pending = pendingWord {
            pending.trailingDelimiters -= 1
            if !pending.delimiters.isEmpty {
                pending.delimiters.removeLast()
            }
            if pending.trailingDelimiters <= 0 {
                buffer = pending.characters
                deletionStart = pending.characters
                pendingWord = nil
            } else {
                pendingWord = pending
            }
        }
        if buffer.isEmpty && pendingWord == nil {
            idleFlushTask?.cancel()
            idleFlushTask = nil
        } else {
            scheduleIdleFlush()
        }
    }

    /// Option+Backspace: the word being typed, or the word just finished, is
    /// gone and must not be counted.
    public func observeDeleteWord() {
        pendingBackspaces += 1
        if !buffer.isEmpty {
            if deletionStart == nil {
                deletionStart = buffer
            }
            buffer.removeAll()
        } else if let pending = pendingWord {
            deletionStart = pending.characters
            pendingWord = nil
        }
        noteDeletedChord()
    }

    /// A chord's whole output deleted before the next word is a misfire:
    /// the wrong word came out. Deleting only part of it is an edit.
    private func noteDeletedChord() {
        defer { deletionStart = nil }
        guard let deleted = deletionStart,
              deleted.allSatisfy({ $0.source == .m4g }),
              isChordBurst(deleted) else { return }
        let text = String(deleted.map(\.character))
        guard let word = MultilingualWordProcessor.words(in: text).first?.text else { return }
        pendingMisfires.append((word, Date()))
    }

    private func flushMisfires() async {
        let misfires = pendingMisfires
        pendingMisfires = []
        for misfire in misfires {
            try? await libraryService.recordMisfire(word: misfire.word, kind: .deleted, at: misfire.at)
        }
    }

    /// Command+Backspace: everything uncommitted on the line is gone.
    public func observeDeleteLine() {
        pendingBackspaces += 1
        buffer.removeAll()
        pendingWord = nil
        idleFlushTask?.cancel()
        idleFlushTask = nil
    }

    /// A hard boundary (Return, Tab, a shortcut, a click, cursor movement):
    /// finish and persist everything, because backspace can no longer be
    /// trusted to edit the previous word.
    public func observeDelimiter(at timestamp: Date = .now) async {
        await finishWord(endedAt: timestamp)
        await commitPendingWord()
        await flushMisfires()
        let keystrokes = pendingKeystrokes
        let backspaces = pendingBackspaces
        pendingKeystrokes = 0
        pendingBackspaces = 0
        try? await libraryService.recordKeyStats(keystrokes: keystrokes, backspaces: backspaces, at: timestamp)
    }

    /// Tab or Right Arrow straight after letters usually accepts an
    /// autocomplete suggestion (Slack mentions, shell completion, inline
    /// predictions). The inserted text never reaches the recorder, so note
    /// that these letters were only the start of the real word.
    public func observeCompletionKey(at timestamp: Date = .now) async {
        let typed = MultilingualWordProcessor.words(in: String(buffer.map(\.character)))
        await observeDelimiter(at: timestamp)
        if typed.count == 1, let word = typed.first?.text {
            try? await libraryService.recordCompletedWord(word, lastUsedAt: timestamp)
        }
    }

    public func recordLiteralText(_ text: String, startedAt: Date, endedAt: Date) async {
        await observeKeyboardText(text, source: .keyboard, startedAt: startedAt, endedAt: endedAt)
    }

    public func recordSoftwareChord(_ chord: ChordEntry, startedAt: Date, endedAt: Date) async {
        await recordChordOutput(
            chord.output,
            matchedChordId: chord.id,
            source: .softwareChord,
            confidence: .exactSoftware,
            ambiguityCount: 0,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    public func recordChordOutput(_ output: String, startedAt: Date, endedAt: Date) async {
        await recordChordOutput(
            output,
            matchedChordId: nil,
            source: .softwareChord,
            confidence: .exactSoftware,
            ambiguityCount: 0,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    public func flush() async {
        await observeDelimiter(at: .now)
    }

    private func finishWord(endedAt: Date) async {
        guard !buffer.isEmpty else { return }
        // Swap state before suspending so a concurrent idle flush cannot
        // persist the same characters twice.
        let previous = pendingWord
        pendingWord = PendingWord(characters: buffer, endedAt: endedAt, trailingDelimiters: 0)
        buffer = []
        if let previous {
            await persist(previous.characters, endedAt: previous.endedAt, joinsNext: false)
        }
    }

    /// Persists the held-back word. `nextWordStarted` is true only when a new
    /// word begins; with a single space between them the two form a phrase.
    private func commitPendingWord(nextWordStarted: Bool = false) async {
        guard let pending = pendingWord else { return }
        pendingWord = nil
        await persist(
            pending.characters,
            endedAt: pending.endedAt,
            joinsNext: nextWordStarted && pending.delimiters == " "
        )
    }

    private func persist(_ characters: [BufferedCharacter], endedAt: Date, joinsNext: Bool) async {
        let rawText = String(characters.map(\.character))
        let words = MultilingualWordProcessor.words(in: rawText)
        guard !words.isEmpty else { return }
        let startedAt = characters.first?.timestamp ?? endedAt
        let avgMs = max(1.0, endedAt.timeIntervalSince(startedAt) * 1_000)

        if words.count == 1,
           let word = words.first?.text,
           let inferred = inferredDeviceChord(for: word, characters: characters) {
            await recordChordOutput(
                word,
                matchedChordId: inferred.matchedChordId,
                source: .m4gHIDConfirmed,
                confidence: inferred.confidence,
                ambiguityCount: inferred.ambiguityCount,
                startedAt: startedAt,
                endedAt: endedAt
            )
            await notePhraseWord(word, handTyped: false, joinsNext: joinsNext, at: endedAt)
            let cycle = await noteSpeed(word: word, method: .m4gChords, endedAt: endedAt)
            wordObserver?(RecordedWord(word: word, source: .m4gHIDConfirmed, avgMs: avgMs, language: words[0].language, cycleMs: cycle))
            return
        }

        guard characters.allSatisfy({ $0.source != .unknown }) else {
            previousWordJoinsNext = false
            lastWordEndedAt = nil
            return
        }
        let source: UsageSource
        if characters.allSatisfy({ $0.source == .m4g }) {
            source = .m4gTyping
        } else {
            source = m4gConnected ? .keyboard : .keyboardAway
        }

        let cycle: Double?
        if words.count == 1, let word = words.first?.text {
            cycle = await noteSpeed(word: word, method: source == .m4gTyping ? .m4gLetters : .keyboard, endedAt: endedAt)
        } else {
            cycle = nil
            lastWordEndedAt = endedAt
        }
        for word in words {
            try? await libraryService.recordWordUsage(
                word: word.text,
                avgMs: avgMs / Double(words.count),
                source: source,
                lastUsedAt: endedAt
            )
            wordObserver?(RecordedWord(word: word.text, source: source, avgMs: avgMs / Double(words.count), language: word.language, cycleMs: cycle))
        }
        if words.count == 1, let word = words.first?.text {
            await notePhraseWord(word, handTyped: true, joinsNext: joinsNext, at: endedAt)
        } else {
            phraseRun = []
            previousWordJoinsNext = false
        }
    }

    /// Records a words-per-minute sample: the word plus its space, over the
    /// time since the previous word ended. Pauses are left out.
    private func noteSpeed(word: String, method: SpeedMethod, endedAt: Date) async -> Double? {
        defer { lastWordEndedAt = endedAt }
        guard let previous = lastWordEndedAt else { return nil }
        let cycle = endedAt.timeIntervalSince(previous)
        guard cycle > 0, cycle <= speedPauseLimit else { return nil }
        let cycleMs = cycle * 1_000
        try? await libraryService.recordSpeedSample(method: method, characters: word.count + 1, cycleMs: cycleMs, at: endedAt)
        return cycleMs
    }

    /// Counts the two- and three-word phrases ending at this word.
    private func notePhraseWord(_ word: String, handTyped: Bool, joinsNext: Bool, at date: Date) async {
        if !previousWordJoinsNext {
            phraseRun = []
        }
        phraseRun.append((word, handTyped))
        if phraseRun.count > 3 {
            phraseRun.removeFirst(phraseRun.count - 3)
        }
        previousWordJoinsNext = joinsNext
        for length in [2, 3] where phraseRun.count >= length {
            let slice = phraseRun.suffix(length)
            try? await libraryService.recordPhrase(
                slice.map(\.word),
                handTyped: slice.allSatisfy(\.handTyped),
                lastUsedAt: date
            )
        }
    }

    private func recordChordOutput(
        _ output: String,
        matchedChordId: UUID?,
        source: UsageSource,
        confidence: ChordUsageConfidence,
        ambiguityCount: Int,
        startedAt: Date,
        endedAt: Date
    ) async {
        let avgMs = max(1.0, endedAt.timeIntervalSince(startedAt) * 1_000)
        try? await libraryService.recordChordUsage(
            output: output,
            matchedChordId: matchedChordId,
            source: source,
            avgMs: avgMs,
            confidence: confidence,
            ambiguityCount: ambiguityCount,
            lastUsedAt: endedAt
        )
        let words = MultilingualWordProcessor.words(in: output)
        for word in words {
            try? await libraryService.recordWordUsage(
                word: word.text,
                avgMs: avgMs / Double(max(words.count, 1)),
                source: source,
                lastUsedAt: endedAt
            )
        }
    }

    private func inferredDeviceChord(
        for word: String,
        characters: [BufferedCharacter]
    ) -> (matchedChordId: UUID?, confidence: ChordUsageConfidence, ambiguityCount: Int)? {
        guard characters.allSatisfy({ $0.source == .m4g }),
              isChordBurst(characters) else {
            return nil
        }

        guard let matches = deviceChordsByOutput[word], !matches.isEmpty else {
            return (nil, .chordBurst, 0)
        }
        if matches.count == 1 {
            return (matches[0].id, .confirmedHardware, 0)
        }
        return (nil, .ambiguousOutput, matches.count)
    }

    /// Chord output arrives a few milliseconds per character, far faster than
    /// anyone types. One slower seam is allowed so a chord finished by a suffix
    /// modifier still counts as chorded.
    private func isChordBurst(_ characters: [BufferedCharacter]) -> Bool {
        guard characters.count >= 2 else { return false }
        let intervals = zip(characters.dropFirst(), characters).map { next, previous in
            next.timestamp.timeIntervalSince(previous.timestamp)
        }
        let slow = intervals.filter { $0 > chordBurstInterval }.count
        let fast = intervals.count - slow
        return slow == 0 || (slow == 1 && fast >= 2)
    }

    private func scheduleIdleFlush() {
        idleFlushTask?.cancel()
        idleFlushTask = Task { [newWordThreshold] in
            do {
                try await Task.sleep(nanoseconds: UInt64(newWordThreshold * 1_000_000_000))
                await self.observeDelimiter()
            } catch {
                return
            }
        }
    }
}
