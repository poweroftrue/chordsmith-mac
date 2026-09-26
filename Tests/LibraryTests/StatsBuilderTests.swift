import Foundation
import XCTest
@testable import Library

final class StatsBuilderTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 12))!
    }

    private func row(_ day: String, _ word: String, _ source: UsageSource, _ frequency: Int, ms: Double = 1_000, language: WordLanguage = .english) -> DailyWordRow {
        DailyWordRow(day: day, word: word, source: source, language: language, frequency: frequency, avgMs: ms)
    }

    func testWeekReportSplitsWordsByHowTheyWereProduced() {
        let report = StatsBuilder(period: .week, now: now, calendar: calendar).build(
            wordRows: [
                row("2026-09-26", "the", .m4gHIDConfirmed, 30, ms: 5),
                row("2026-09-26", "hermes", .m4gTyping, 10, ms: 1_200),
                row("2026-09-27", "hermes", .keyboard, 20, ms: 600),
                row("2026-09-27", "hte", .keyboard, 5, ms: 300),
                row("2026-09-27", "مرحبا", .keyboard, 4, language: .arabic),
                row("2026-09-10", "old", .keyboard, 99)
            ],
            chordRows: [(day: "2026-09-26", frequency: 30)],
            addedChordDays: ["2026-09-25"],
            keyRows: [(day: "2026-09-27", keystrokes: 200, backspaces: 10)],
            chordedWords: ["the": ["t", "e"]],
            typoWords: ["hte"],
            mergedWords: [:]
        )

        XCTAssertEqual(report.buckets.count, 7)
        XCTAssertEqual(report.totals.words, 69)
        XCTAssertEqual(report.totals.chordedWords, 30)
        XCTAssertEqual(report.totals.m4gTypedWords, 10)
        XCTAssertEqual(report.totals.keyboardWords, 29)
        XCTAssertEqual(report.totals.chordsUsed, 30)
        XCTAssertEqual(report.totals.coveredWords, 30)
        XCTAssertEqual(report.totals.typoWords, 5)
        XCTAssertEqual(report.totals.chordsAdded, 1)
        XCTAssertEqual(report.totals.backspaceRate ?? 0, 0.05, accuracy: 0.0001)
        // 10 × "hermes" = 60 letters in 12 s → 60 WPM.
        XCTAssertEqual(report.totals.m4gWPM ?? 0, 60, accuracy: 0.1)
        XCTAssertEqual(report.previousTotals.words, 0)
        XCTAssertEqual(report.chordStreakDays, 1)
        XCTAssertEqual(report.arabicWords, 4)
        XCTAssertEqual(report.topChorded.first?.word, "the")
        XCTAssertEqual(report.topChorded.first?.chordInput, ["t", "e"])
        XCTAssertEqual(report.topUnchorded.first?.word, "hermes")
    }

    func testChordMeasuresStartWhenTrackingStarts() {
        let report = StatsBuilder(period: .week, now: now, calendar: calendar).build(
            wordRows: [
                row("2026-09-22", "the", .keyboard, 100),
                row("2026-09-26", "the", .m4gHIDConfirmed, 40, ms: 5),
                row("2026-09-26", "the", .keyboard, 10)
            ],
            chordRows: [],
            addedChordDays: [],
            keyRows: [],
            chordedWords: ["the": ["t", "e"]],
            typoWords: [],
            mergedWords: [:],
            attributionStartDay: "2026-09-26"
        )

        XCTAssertEqual(report.totals.chordRate ?? 0, 40.0 / 150.0, accuracy: 0.001)
        XCTAssertEqual(report.chordTotals.chordRate ?? 0, 0.8, accuracy: 0.001)
        XCTAssertFalse(report.hasComparablePreviousChords)
        XCTAssertFalse(report.isTracked(report.buckets[0]))
        XCTAssertTrue(report.isTracked(report.buckets[5]))
    }

    func testYearReportBucketsByMonthAndMergesAliases() {
        let report = StatsBuilder(period: .year, now: now, calendar: calendar).build(
            wordRows: [
                row("2026-08-03", "zelv", .keyboard, 7),
                row("2026-09-03", "zelvora", .keyboard, 3)
            ],
            chordRows: [],
            addedChordDays: [],
            keyRows: [],
            chordedWords: [:],
            typoWords: [],
            mergedWords: ["zelv": "zelvora"]
        )

        XCTAssertEqual(report.buckets.count, 12)
        XCTAssertEqual(report.buckets.last?.words, 3)
        XCTAssertEqual(report.buckets[report.buckets.count - 2].words, 7)
        XCTAssertEqual(report.topUnchorded.first?.word, "zelvora")
        XCTAssertEqual(report.topUnchorded.first?.count, 10)
    }

    func testSpeedAndErrorRatesPerMethod() {
        var bucket = StatsBucket(start: Date())
        bucket.chordedWords = 90
        bucket.keyboardWords = 60
        bucket.m4gTypedWords = 40
        bucket.chordsUsed = 90
        bucket.typoWords = 5
        bucket.deletedMisfires = 6
        bucket.garbledMisfires = 4
        bucket.chordSpeedChars = 500
        bucket.chordSpeedMs = 30_000
        bucket.m4gLetterSpeedChars = 250
        bucket.m4gLetterSpeedMs = 60_000
        bucket.keyboardSpeedChars = 400
        bucket.keyboardSpeedMs = 60_000

        XCTAssertEqual(bucket.typoRate ?? 0, 0.05, accuracy: 0.0001)
        XCTAssertEqual(bucket.misfireRate ?? 0, 10.0 / 96.0, accuracy: 0.0001)
        XCTAssertEqual(bucket.errorRate ?? 0, 15.0 / 196.0, accuracy: 0.0001)
        XCTAssertEqual(bucket.chordSpeedWPM ?? 0, 200, accuracy: 0.1)
        XCTAssertEqual(bucket.m4gLetterSpeedWPM ?? 0, 50, accuracy: 0.1)
        XCTAssertEqual(bucket.keyboardSpeedWPM ?? 0, 80, accuracy: 0.1)
        XCTAssertEqual(bucket.m4gBlendedWPM ?? 0, 100, accuracy: 0.1)
    }

    func testGarbledChordBurstsAndSpeedRowsReachTheReport() {
        let calendar = self.calendar
        let report = StatsBuilder(period: .week, now: now, calendar: calendar).build(
            wordRows: [row("2026-09-27", "the", .m4gHIDConfirmed, 20, ms: 5)],
            chordRows: [(day: "2026-09-27", frequency: 20)],
            addedChordDays: [],
            keyRows: [],
            chordedWords: ["the": ["t", "e"]],
            typoWords: [],
            mergedWords: [:],
            speedRows: [(day: "2026-09-27", method: .m4gChords, characters: 100, ms: 6_000)],
            misfireRows: [
                (day: "2026-09-27", word: "the", kind: .deleted, frequency: 2),
                (day: "2026-09-27", word: "tseh", kind: .garbled, frequency: 1)
            ]
        )

        XCTAssertEqual(report.totals.chordSpeedWPM ?? 0, 200, accuracy: 0.1)
        XCTAssertEqual(report.totals.misfires, 3)
        XCTAssertEqual(report.topMisfires.first?.word, "the")
        XCTAssertEqual(report.topMisfires.first?.chordInput, ["t", "e"])
        XCTAssertNotNil(report.speedTrackingStart)
    }
}

