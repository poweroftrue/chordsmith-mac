import Foundation
import Library

public typealias TypingRecorder = UsageRecorder

public actor UsageRecorder {
    private struct BufferedCharacter {
        let character: Character
        let timestamp: Date
        let source: PhysicalInputSource
    }

    private let libraryService: LibraryService
    private var buffer: [BufferedCharacter] = []
    private var deviceChordsByOutput: [String: [ChordEntry]] = [:]
    private var idleFlushTask: Task<Void, Never>?

    private let newWordThreshold: TimeInterval = 5.0
    private let chordBurstAverageInterval: TimeInterval = 0.015

    public init(libraryService: LibraryService) {
        self.libraryService = libraryService
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
        let step = endedAt.timeIntervalSince(startedAt) / Double(max(characters.count, 1))

        for (index, character) in characters.enumerated() {
            let timestamp = startedAt.addingTimeInterval(step * Double(index))
            let continuesWord = MultilingualWordProcessor.isCoreWordCharacter(character) ||
                (MultilingualWordProcessor.isWordJoiner(character) && !buffer.isEmpty)
            if continuesWord {
                if let last = buffer.last,
                   timestamp.timeIntervalSince(last.timestamp) > newWordThreshold {
                    await flushBuffer(endedAt: last.timestamp)
                }
                buffer.append(
                    BufferedCharacter(
                        character: character,
                        timestamp: timestamp,
                        source: source
                    )
                )
                scheduleIdleFlush()
            } else {
                await flushBuffer(endedAt: timestamp)
            }
        }
    }

    public func observeBackspace() {
        if !buffer.isEmpty {
            buffer.removeLast()
        }
        if buffer.isEmpty {
            idleFlushTask?.cancel()
            idleFlushTask = nil
        } else {
            scheduleIdleFlush()
        }
    }

    public func observeDelimiter(at timestamp: Date = .now) async {
        await flushBuffer(endedAt: timestamp)
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
        await flushBuffer(endedAt: .now)
    }

    private func flushBuffer(endedAt: Date) async {
        idleFlushTask?.cancel()
        idleFlushTask = nil

        let rawText = String(buffer.map(\.character))
        let characters = buffer
        buffer = []

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
            return
        }

        guard characters.allSatisfy({ $0.source != .unknown }) else {
            return
        }
        let source: UsageSource = characters.allSatisfy({ $0.source == .m4g })
            ? .m4gTyping
            : .keyboard

        for word in words {
            try? await libraryService.recordWordUsage(
                word: word.text,
                avgMs: avgMs / Double(words.count),
                source: source,
                lastUsedAt: endedAt
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
        guard let matches = deviceChordsByOutput[word],
              !matches.isEmpty,
              characters.allSatisfy({ $0.source == .m4g }),
              isFastBurst(characters) else {
            return nil
        }

        if matches.count == 1 {
            return (matches[0].id, .confirmedHardware, 0)
        }
        return (nil, .ambiguousOutput, matches.count)
    }

    private func isFastBurst(_ characters: [BufferedCharacter]) -> Bool {
        guard characters.count >= 2,
              let first = characters.first?.timestamp,
              let last = characters.last?.timestamp else {
            return false
        }
        let averageInterval = last.timeIntervalSince(first) / Double(max(characters.count - 1, 1))
        return averageInterval <= chordBurstAverageInterval
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
