import Foundation
import XCTest
@testable import Engine
@testable import Library

final class EngineTests: XCTestCase {
    func testKeyMapVariesByProfile() {
        XCTAssertEqual(KeyMap.token(for: 1, profile: .ansiQwerty), "s")
        XCTAssertEqual(KeyMap.token(for: 1, profile: .ansiColemak), "r")
        XCTAssertEqual(KeyMap.token(for: 4, profile: .ansiColemakDH), "m")
    }

    @MainActor
    func testChordEngineThresholdsAndMatching() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("charaworder.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let engine = ChordEngine(recorder: recorder)

        XCTAssertEqual(engine.debugThreshold(for: 1), 0.05, accuracy: 0.0001)
        XCTAssertEqual(engine.debugThreshold(for: 3), 0.075, accuracy: 0.0001)
        XCTAssertEqual(engine.debugThreshold(for: 5), 0.125, accuracy: 0.0001)

        let chord = ChordEntry(
            inputKeys: ["h", "r", "t"],
            output: "there",
            profile: .ansiQwerty,
            deploymentTarget: .software,
            source: "test"
        )
        engine.updateChords([chord])

        let match = try XCTUnwrap(engine.debugMatch(tokens: ["r", "t", "h"]))
        XCTAssertEqual(match.output, "there")
        XCTAssertNil(engine.debugMatch(tokens: ["r", "t"]))
    }

    @MainActor
    func testChordEnginePassesThroughWhenNoSoftwareChordsAreLoaded() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("charaworder.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let engine = ChordEngine(recorder: recorder)

        engine.updateChords([])
        XCTAssertFalse(engine.debugShouldInterceptKeyboardEvents())

        engine.updateChords([
            ChordEntry(
                inputKeys: ["h", "r", "t"],
                output: "there",
                profile: .ansiQwerty,
                deploymentTarget: .software,
                source: "test"
            )
        ])
        XCTAssertTrue(engine.debugShouldInterceptKeyboardEvents())
    }

    @MainActor
    func testChordEngineExcludesHostAppBundleID() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("charaworder.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let engine = ChordEngine(recorder: recorder)

        if let bundleID = Bundle.main.bundleIdentifier {
            XCTAssertTrue(engine.debugIsExcluded(bundleID: bundleID))
        }
        XCTAssertFalse(engine.debugIsExcluded(bundleID: "com.example.not-excluded"))
    }

    func testTypingRecorderPersistsAggregatesOnly() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("charaworder.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let endedAt = Date(timeIntervalSince1970: 2_000.4)

        await recorder.recordLiteralText("hello ", startedAt: startedAt, endedAt: endedAt)
        await recorder.recordChordOutput("there", startedAt: startedAt, endedAt: endedAt)
        await recorder.flush()

        let words = try await library.wordStats(limit: 10)
        XCTAssertTrue(words.contains(where: { $0.word == "hello" && $0.frequency == 1 }))
        XCTAssertTrue(words.contains(where: { $0.word == "there" && $0.frequency == 1 }))

        let chordStats = try await library.chordStats(limit: 10)
        let thereChord = try XCTUnwrap(chordStats.first(where: { $0.output == "there" }))
        XCTAssertEqual(thereChord.frequency, 1)
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
