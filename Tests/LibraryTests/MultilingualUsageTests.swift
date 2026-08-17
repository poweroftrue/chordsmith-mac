import Foundation
import XCTest
@testable import Library

final class MultilingualUsageTests: XCTestCase {
    func testNaturalLanguageTokenizationAndArabicNormalization() {
        let words = MultilingualWordProcessor.words(
            in: "Hello, مَرْحَبًا hello-world الـعَرَبِيَّةُ"
        )

        XCTAssertEqual(words.map(\.text), ["hello", "مرحبا", "hello", "world", "العربية"])
        XCTAssertEqual(
            words.map(\.language),
            [.english, .arabic, .english, .english, .arabic]
        )
    }

    func testWordUsageUsesSingleStatementUpsertsAndKeepsLanguage() async throws {
        let temporary = try MultilingualTemporaryDirectory()
        defer { temporary.remove() }
        let library = try LibraryService(databaseURL: temporary.databaseURL)
        let now = Date()

        try await library.recordWordUsage(
            word: "HELLO",
            avgMs: 100,
            source: .keyboard,
            frequencyDelta: 2,
            lastUsedAt: now
        )
        try await library.recordWordUsage(
            word: "hello",
            avgMs: 400,
            source: .keyboard,
            frequencyDelta: 1,
            lastUsedAt: now.addingTimeInterval(1)
        )
        try await library.recordWordUsage(
            word: "مَرْحَبًا",
            avgMs: 300,
            source: .keyboard,
            lastUsedAt: now
        )

        let words = try await library.wordStats(limit: 10)
        let hello = try XCTUnwrap(words.first { $0.word == "hello" })
        XCTAssertEqual(hello.frequency, 3)
        XCTAssertEqual(hello.avgMs, 200, accuracy: 0.001)
        XCTAssertEqual(hello.language, .english)
        XCTAssertEqual(words.first { $0.word == "مرحبا" }?.language, .arabic)
    }

    func testCoverageReportRanksArabicAndEnglishCoveredAndUncoveredWords() async throws {
        let temporary = try MultilingualTemporaryDirectory()
        defer { temporary.remove() }
        let library = try LibraryService(databaseURL: temporary.databaseURL)
        let helloChord = ChordEntry(
            inputKeys: ["h", "e"],
            output: "hello",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )
        let arabicChord = ChordEntry(
            inputKeys: ["m", "r"],
            output: "مرحبا",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )
        try await library.upsertChord(helloChord)
        try await library.upsertChord(arabicChord)

        try await library.recordWordUsage(word: "hello", avgMs: 200, source: .keyboard, frequencyDelta: 3)
        try await library.recordWordUsage(word: "world", avgMs: 200, source: .keyboard, frequencyDelta: 5)
        try await library.recordWordUsage(word: "مَرْحَبًا", avgMs: 200, source: .keyboard, frequencyDelta: 2)
        try await library.recordWordUsage(word: "العربية", avgMs: 200, source: .keyboard, frequencyDelta: 4)

        let all = try await library.wordCoverageReport(days: nil)
        XCTAssertEqual(all.totalOccurrences, 14)
        XCTAssertEqual(all.coveredOccurrences, 5)
        XCTAssertEqual(all.uniqueWords, 4)
        XCTAssertEqual(all.coveredUniqueWords, 2)
        XCTAssertEqual(all.uncoveredWords.map(\.word), ["world", "العربية"])
        XCTAssertEqual(all.coveredWords.map(\.word), ["hello", "مرحبا"])
        XCTAssertEqual(all.coveredWords.first { $0.word == "hello" }?.matchingChords.first?.id, helloChord.id)

        let arabic = try await library.wordCoverageReport(days: nil, language: .arabic)
        XCTAssertEqual(arabic.totalOccurrences, 6)
        XCTAssertEqual(arabic.coveredOccurrences, 2)
        XCTAssertEqual(arabic.coveredWords.map(\.word), ["مرحبا"])
        XCTAssertEqual(arabic.uncoveredWords.map(\.word), ["العربية"])
    }
}

private struct MultilingualTemporaryDirectory {
    let url: URL
    var databaseURL: URL { url.appendingPathComponent("chordsmith.sqlite3") }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
