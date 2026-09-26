import Foundation
import XCTest
@testable import Library

final class CoachingTests: XCTestCase {
    func testPhrasePlanUsesInitialsPlusSpaceAndStaysConflictFree() {
        let plan = GrowthPlanner().planPhrases(
            phrases: [
                PhraseUsage(phrase: "can you", wordCount: 2, frequency: 40, handFrequency: 30),
                PhraseUsage(phrase: "could you", wordCount: 2, frequency: 20, handFrequency: 20),
                PhraseUsage(phrase: "thank you", wordCount: 2, frequency: 2, handFrequency: 2),
                PhraseUsage(phrase: "of the", wordCount: 2, frequency: 30, handFrequency: 0)
            ],
            wordAvgMs: ["can": 300, "you": 300, "could": 500],
            existingChords: [
                ChordEntry(inputKeys: ["o", "t", "space"], output: "of the", profile: .cc2A1, deploymentTarget: .device, source: "test")
            ],
            bannedInputs: []
        )

        XCTAssertEqual(plan.map(\.phrase), ["can you", "could you"])
        XCTAssertEqual(Set(plan[0].candidates[0].inputKeys), ["c", "y", "space"])
        let firstInputs = plan.compactMap { $0.candidates.first.map { ChordEntry.normalizeInputKeys($0.inputKeys) } }
        XCTAssertEqual(Set(firstInputs).count, firstInputs.count)
    }

    func testTodayUsageTracksChordRateGoalAndLetterSpeed() {
        var today = TodayUsage()
        today.record(word: "the", source: .m4gHIDConfirmed, avgMs: 5, isGoalWord: true)
        today.record(word: "the", source: .keyboard, avgMs: 200, isGoalWord: true)
        for _ in 0..<10 {
            today.record(word: "hello", source: .m4gTyping, avgMs: 1_000, isGoalWord: false)
        }

        XCTAssertEqual(today.words, 12)
        XCTAssertEqual(today.chordRate ?? 0, 1.0 / 12.0, accuracy: 0.0001)
        XCTAssertEqual(today.goalRate ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(today.handCounts["hello"], 10)
        // 50 letters in 10 s → 60 WPM.
        XCTAssertEqual(today.m4gWPM ?? 0, 60, accuracy: 0.1)
    }

    func testSpeedDrillTimesLetterPairsAndIgnoresPauses() {
        let start = Date()
        let typed: [(character: Character, time: Date)] = [
            ("t", start),
            ("h", start.addingTimeInterval(0.2)),
            ("e", start.addingTimeInterval(0.3)),
            (" ", start.addingTimeInterval(0.4)),
            ("t", start.addingTimeInterval(3)),
            ("h", start.addingTimeInterval(3.3))
        ]
        let timings = SpeedDrillBuilder.bigramTimings(typed: typed)
        XCTAssertEqual(timings["th"]?.count, 2)
        XCTAssertEqual(timings["th"]?.totalMs ?? 0, 500, accuracy: 1)
        XCTAssertEqual(timings["he"]?.count, 1)
        XCTAssertNil(timings["e "])
    }

    func testSpeedDrillLeansOnSlowPairs() {
        let pool = ["the", "then", "other", "apple", "zebra", "quick", "brown", "fox", "jumps", "lazy", "dogs", "moon"]
        let words = SpeedDrillBuilder.words(pool: pool, slowBigrams: ["th"], count: 10, seed: 42)
        XCTAssertEqual(words.count, 10)
        XCTAssertEqual(Set(words).count, 10)
        XCTAssertTrue(words.contains("the") && words.contains("then") && words.contains("other"))
    }

    func testSpeedDrillHistoryAndSlowPairsPersist() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try LibraryService(databaseURL: directory.appendingPathComponent("chordsmith.sqlite3"))

        let result = SpeedDrillResult(wpm: 48, accuracy: 0.96, characters: 90, slowBigrams: [BigramTiming(bigram: "th", averageMs: 240, count: 5)])
        try await library.saveSpeedDrill(result, bigrams: ["th": (1_200, 5), "he": (500, 5)])
        try await library.saveSpeedDrill(SpeedDrillResult(wpm: 52, accuracy: 0.98, characters: 90, slowBigrams: []), bigrams: ["th": (1_000, 5)])

        let history = try await library.speedDrillHistory()
        XCTAssertEqual(history.map(\.wpm), [48, 52])
        let slow = try await library.slowestDrillBigrams()
        XCTAssertEqual(slow.first?.bigram, "th")
        XCTAssertEqual(slow.first?.averageMs ?? 0, 220, accuracy: 0.1)
    }
}
