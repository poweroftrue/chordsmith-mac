import Foundation
import Library

public actor TypingRecorder {
    private let libraryService: LibraryService
    private var buffer = ""
    private var bufferStartedAt: Date?

    public init(libraryService: LibraryService) {
        self.libraryService = libraryService
    }

    public func recordLiteralText(_ text: String, startedAt: Date, endedAt: Date) async {
        let totalMilliseconds = max(50.0, endedAt.timeIntervalSince(startedAt) * 1_000)
        let averageMilliseconds = totalMilliseconds / Double(max(text.count, 1))
        for character in text {
            if isWordCharacter(character) {
                if buffer.isEmpty {
                    bufferStartedAt = startedAt
                }
                buffer.append(character.lowercased())
            } else {
                await flushBuffer(defaultAverageMilliseconds: averageMilliseconds, endedAt: endedAt)
            }
        }

        if let last = text.last, !isWordCharacter(last) {
            await flushBuffer(defaultAverageMilliseconds: averageMilliseconds, endedAt: endedAt)
        }
    }

    public func recordChordOutput(_ output: String, startedAt: Date, endedAt: Date) async {
        try? await libraryService.recordChordOutput(output)
        await recordLiteralText(output, startedAt: startedAt, endedAt: endedAt)
    }

    public func flush() async {
        await flushBuffer(defaultAverageMilliseconds: 120, endedAt: .now)
    }

    private func flushBuffer(defaultAverageMilliseconds: Double, endedAt: Date) async {
        let word = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            buffer = ""
            bufferStartedAt = nil
        }

        guard !word.isEmpty else { return }
        let startedAt = bufferStartedAt ?? endedAt
        let elapsedMilliseconds = max(defaultAverageMilliseconds, endedAt.timeIntervalSince(startedAt) * 1_000)
        try? await libraryService.upsertWordStat(word: word, avgMs: elapsedMilliseconds, source: "software")
    }

    private func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || ["'", "-", "_", "/", "~"].contains(character)
    }
}
