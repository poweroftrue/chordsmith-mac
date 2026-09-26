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

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
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

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
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

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
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

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
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

    func testUsageRecorderRecordsSlowKeyboardWord() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let start = Date()

        await recorder.observeKeyboardText("t", startedAt: start, endedAt: start)
        await recorder.observeKeyboardText("h", startedAt: start.addingTimeInterval(0.18), endedAt: start.addingTimeInterval(0.18))
        await recorder.observeKeyboardText("e", startedAt: start.addingTimeInterval(0.36), endedAt: start.addingTimeInterval(0.36))
        await recorder.observeDelimiter(at: start.addingTimeInterval(0.5))

        let words = try await library.dailyWordUsage(days: 1, limit: 10)
        let word = try XCTUnwrap(words.first(where: { $0.word == "the" }))
        XCTAssertEqual(word.frequency, 1)
        XCTAssertEqual(word.source, .keyboard)

        let chords = try await library.dailyChordUsage(days: 1, limit: 10)
        XCTAssertTrue(chords.isEmpty)
    }

    func testUsageRecorderDoesNotInferFastNormalKeyboardTextAsM4G() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let chord = ChordEntry(
            inputKeys: ["t", "h", "e"],
            output: "the",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test-device"
        )
        let start = Date()

        await recorder.updateDeviceChords([chord])
        await recorder.observeKeyboardText(
            "the",
            source: .keyboard,
            startedAt: start,
            endedAt: start.addingTimeInterval(0.006)
        )
        await recorder.observeDelimiter(at: start.addingTimeInterval(0.01))

        let words = try await library.dailyWordUsage(days: 1, limit: 10)
        XCTAssertEqual(words.first { $0.word == "the" }?.source, .keyboard)
        let chords = try await library.dailyChordUsage(days: 1, limit: 10)
        XCTAssertTrue(chords.isEmpty)
    }

    func testUsageRecorderLabelsNonChordM4GTypingByPhysicalSource() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let start = Date()

        await recorder.observeKeyboardText(
            "hello",
            source: .m4g,
            startedAt: start,
            endedAt: start.addingTimeInterval(0.5)
        )
        await recorder.observeDelimiter(at: start.addingTimeInterval(0.6))

        let words = try await library.dailyWordUsage(days: 1, limit: 10)
        XCTAssertEqual(words.first { $0.word == "hello" }?.source, .m4gTyping)
        let chords = try await library.dailyChordUsage(days: 1, limit: 10)
        XCTAssertTrue(chords.isEmpty)
    }

    func testUsageRecorderDoesNotInferUnattributedTextAsM4G() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let chord = ChordEntry(
            inputKeys: ["t", "h", "e"],
            output: "the",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test-device"
        )
        let start = Date()

        await recorder.updateDeviceChords([chord])
        await recorder.observeKeyboardText(
            "the",
            source: .unknown,
            startedAt: start,
            endedAt: start.addingTimeInterval(0.006)
        )
        await recorder.observeDelimiter(at: start.addingTimeInterval(0.01))

        let words = try await library.dailyWordUsage(days: 1, limit: 10)
        XCTAssertFalse(words.contains { $0.word == "the" })
        let chords = try await library.dailyChordUsage(days: 1, limit: 10)
        XCTAssertTrue(chords.isEmpty)
    }

    func testHIDInputCorrelatorMatchesByKeyAndTimestampAndConsumesMatch() {
        var correlator = HIDInputCorrelator(matchingToleranceNanoseconds: 40, retentionNanoseconds: 250)
        correlator.record(HIDKeySample(timestampNanoseconds: 1_000, virtualKeyCode: 0, source: .m4g))
        correlator.record(HIDKeySample(timestampNanoseconds: 1_010, virtualKeyCode: 11, source: .m4g))

        XCTAssertEqual(correlator.source(for: 1_015, virtualKeyCode: 11), .m4g)
        XCTAssertEqual(correlator.source(for: 1_016, virtualKeyCode: 11), .unknown)
        XCTAssertEqual(correlator.source(for: 1_020, virtualKeyCode: 0), .m4g)
    }

    func testHIDInputCorrelatorRejectsDifferentKeyAndStaleSample() {
        var correlator = HIDInputCorrelator(matchingToleranceNanoseconds: 40, retentionNanoseconds: 250)
        correlator.record(HIDKeySample(timestampNanoseconds: 1_000, virtualKeyCode: 0, source: .m4g))

        XCTAssertEqual(correlator.source(for: 1_020, virtualKeyCode: 11), .unknown)
        XCTAssertEqual(correlator.source(for: 1_100, virtualKeyCode: 0), .unknown)
    }

    func testM4GHIDHalfIdentityUsesKnownUSBIdentityOrProductName() {
        XCTAssertTrue(HIDKeyboardDeviceIdentity(
            product: "CharaChorder M4G S3",
            manufacturer: "CharaChorder",
            vendorID: 0x303A,
            productID: 0x829A,
            locationID: 1
        ).isM4GHalf)
        XCTAssertTrue(HIDKeyboardDeviceIdentity(
            product: "Unknown",
            manufacturer: "Unknown",
            vendorID: 0x303A,
            productID: 0x829A,
            locationID: 1
        ).isM4GHalf)
        XCTAssertFalse(HIDKeyboardDeviceIdentity(
            product: "Apple Internal Keyboard / Trackpad",
            manufacturer: "Apple Inc.",
            vendorID: 0x05AC,
            productID: 0x0342,
            locationID: 51
        ).isM4GHalf)
    }

    func testM4GStatusTreatsTwoHIDEndpointsAsBothHalvesOfOneMasterForge() {
        let status = HIDInputMonitorStatus(
            isMonitoring: true,
            m4gHalfCount: 2,
            errorCode: nil
        )

        XCTAssertEqual(
            status.displayText,
            "Physical Master Forge detection active (both halves)"
        )
    }

    func testM4GHIDUsageMapsToMacVirtualKeyCode() {
        XCTAssertEqual(HIDInputSourceMonitor.virtualKeyCode(forHIDUsage: 0x04), 0)
        XCTAssertEqual(HIDInputSourceMonitor.virtualKeyCode(forHIDUsage: 0x1D), 6)
        XCTAssertEqual(HIDInputSourceMonitor.virtualKeyCode(forHIDUsage: 0x2C), 49)
        XCTAssertNil(HIDInputSourceMonitor.virtualKeyCode(forHIDUsage: 0xFFFF))
    }

    func testM4GKeyboardUsageHandlesExpandedAndRawArrayElements() {
        XCTAssertEqual(
            HIDInputSourceMonitor.keyboardUsage(elementUsage: 0x04, isArray: true, integerValue: 1),
            0x04
        )
        XCTAssertEqual(
            HIDInputSourceMonitor.keyboardUsage(elementUsage: UInt32.max, isArray: true, integerValue: 0x04),
            0x04
        )
        XCTAssertEqual(
            HIDInputSourceMonitor.keyboardUsage(elementUsage: 0xFFFF, isArray: true, integerValue: 0x1D),
            0x1D
        )
        XCTAssertNil(
            HIDInputSourceMonitor.keyboardUsage(elementUsage: 0x04, isArray: true, integerValue: 0)
        )
    }

    func testUsageRecorderConfirmsFastM4GChordAndCountsWordOnce() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let chord = ChordEntry(
            inputKeys: ["t", "h", "e"],
            output: "the",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test-device"
        )
        let start = Date()

        await recorder.updateDeviceChords([chord])
        await recorder.observeKeyboardText(
            "the",
            source: .m4g,
            startedAt: start,
            endedAt: start.addingTimeInterval(0.006)
        )
        await recorder.observeDelimiter(at: start.addingTimeInterval(0.01))

        let chordUsage = try await library.dailyChordUsage(days: 1, limit: 10)
        let inferred = try XCTUnwrap(chordUsage.first(where: { $0.output == "the" }))
        XCTAssertEqual(inferred.frequency, 1)
        XCTAssertEqual(inferred.source, .m4gHIDConfirmed)
        XCTAssertEqual(inferred.confidence, .confirmedHardware)
        XCTAssertEqual(inferred.matchedChordId, chord.id)
        XCTAssertEqual(inferred.ambiguityCount, 0)

        let words = try await library.dailyWordUsage(days: 1, limit: 10)
        XCTAssertEqual(words.filter { $0.word == "the" }.reduce(0) { $0 + $1.frequency }, 1)
        let inferredWord = try XCTUnwrap(words.first(where: { $0.word == "the" }))
        XCTAssertEqual(inferredWord.source, .m4gHIDConfirmed)
    }

    func testUsageRecorderMarksDuplicateHardwareOutputsAsAmbiguous() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let first = ChordEntry(inputKeys: ["t", "h", "e"], output: "the", profile: .cc2A1, deploymentTarget: .device, source: "test-device")
        let second = ChordEntry(inputKeys: ["h", "r", "t"], output: "the", profile: .cc2A1, deploymentTarget: .device, source: "test-device")
        let start = Date()

        await recorder.updateDeviceChords([first, second])
        await recorder.observeKeyboardText(
            "the",
            source: .m4g,
            startedAt: start,
            endedAt: start.addingTimeInterval(0.006)
        )
        await recorder.observeDelimiter(at: start.addingTimeInterval(0.01))

        let chordUsage = try await library.dailyChordUsage(days: 1, limit: 10)
        let ambiguous = try XCTUnwrap(chordUsage.first(where: { $0.output == "the" }))
        XCTAssertNil(ambiguous.matchedChordId)
        XCTAssertEqual(ambiguous.source, .m4gHIDConfirmed)
        XCTAssertEqual(ambiguous.confidence, .ambiguousOutput)
        XCTAssertEqual(ambiguous.ambiguityCount, 2)
    }

    func testUsageRecorderBackspaceEditsPendingWord() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let start = Date()

        await recorder.observeKeyboardText("thr", startedAt: start, endedAt: start.addingTimeInterval(0.4))
        await recorder.observeBackspace()
        await recorder.observeKeyboardText("e", startedAt: start.addingTimeInterval(0.5), endedAt: start.addingTimeInterval(0.5))
        await recorder.observeDelimiter(at: start.addingTimeInterval(0.6))

        let words = try await library.dailyWordUsage(days: 1, limit: 10)
        XCTAssertTrue(words.contains { $0.word == "the" && $0.frequency == 1 })
        XCTAssertFalse(words.contains { $0.word == "ther" })
    }

    func testUsageRecorderUsesUnicodeWordBoundaries() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let start = Date()

        await recorder.observeKeyboardText("alpha/beta1gamma", startedAt: start, endedAt: start.addingTimeInterval(0.8))
        await recorder.observeDelimiter(at: start.addingTimeInterval(0.9))

        let words = try await library.dailyWordUsage(days: 1, limit: 10)
        XCTAssertTrue(words.contains { $0.word == "alpha" })
        XCTAssertTrue(words.contains { $0.word == "beta" })
        XCTAssertTrue(words.contains { $0.word == "gamma" })
        XCTAssertFalse(words.contains { $0.word == "alpha/beta1gamma" })
    }

    func testUsageRecorderAggregatesArabicWithoutTashkeel() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let start = Date()

        await recorder.observeKeyboardText(
            "مَرْحَبًا مرحبا ",
            startedAt: start,
            endedAt: start.addingTimeInterval(1)
        )
        await recorder.flush()

        let words = try await library.dailyWordUsage(days: 1, limit: 10)
        let arabic = try XCTUnwrap(words.first { $0.word == "مرحبا" })
        XCTAssertEqual(arabic.frequency, 2)
        XCTAssertEqual(arabic.language, .arabic)
    }

    func testEventClockNormalizesMachTicksAndNanoseconds() {
        let numer: UInt64 = 125
        let denom: UInt64 = 3
        let now: UInt64 = 528_550_740_000_000
        let fiveMillisecondsAgo = now - 5_000_000

        // Keyboard events at the HID tap on Apple silicon carry mach ticks.
        let ticks = fiveMillisecondsAgo * denom / numer
        let fromTicks = EventClock.uptimeNanoseconds(forEventTimestamp: ticks, now: now, numer: numer, denom: denom)
        XCTAssertLessThan(max(fromTicks, fiveMillisecondsAgo) - min(fromTicks, fiveMillisecondsAgo), 1_000)

        // Other events carry nanoseconds already.
        XCTAssertEqual(
            EventClock.uptimeNanoseconds(forEventTimestamp: fiveMillisecondsAgo, now: now, numer: numer, denom: denom),
            fiveMillisecondsAgo
        )
        // Synthetic events have no timestamp; implausible values fall back to now.
        XCTAssertEqual(EventClock.uptimeNanoseconds(forEventTimestamp: 0, now: now, numer: numer, denom: denom), now)
        XCTAssertEqual(EventClock.uptimeNanoseconds(forEventTimestamp: 42, now: now, numer: numer, denom: denom), now)
    }

    func testHIDCorrelatorMatchesAfterNormalizingTickTimestamps() {
        var correlator = HIDInputCorrelator()
        let hidNanoseconds = EventClock.nanoseconds(fromMachTicks: 12_685_217_723_043)
        correlator.record(HIDKeySample(timestampNanoseconds: hidNanoseconds, virtualKeyCode: 17, source: .m4g))

        let keyEventTicks: UInt64 = 12_685_217_768_310
        let normalized = EventClock.uptimeNanoseconds(
            forEventTimestamp: keyEventTicks,
            now: EventClock.nanoseconds(fromMachTicks: keyEventTicks + 1_000),
            numer: 125,
            denom: 3
        )
        XCTAssertEqual(correlator.source(for: normalized, virtualKeyCode: 17), .m4g)
    }

    func testUsageRecorderReopensWordWhenSuffixModifierDeletesTheSpace() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let start = Date()

        // Chord "go", then a CCOS -ing modifier: backspace the space, append "ing ".
        await recorder.observeKeyboardText("go ", source: .m4g, startedAt: start, endedAt: start.addingTimeInterval(0.006))
        await recorder.observeBackspace()
        await recorder.observeKeyboardText("ing ", source: .m4g, startedAt: start.addingTimeInterval(0.2), endedAt: start.addingTimeInterval(0.208))
        await recorder.flush()

        let words = try await library.dailyWordUsage(days: 1, limit: 10)
        XCTAssertEqual(words.map(\.word), ["going"])
        XCTAssertEqual(words.first?.source, .m4gHIDConfirmed)
        let chords = try await library.dailyChordUsage(days: 1, limit: 10)
        XCTAssertEqual(chords.first?.output, "going")
        XCTAssertEqual(chords.first?.confidence, .chordBurst)
    }

    func testUsageRecorderCountsTheCorrectedWordAfterBackspacingIntoIt() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let start = Date()

        await recorder.observeKeyboardText("teh ", startedAt: start, endedAt: start.addingTimeInterval(0.4))
        await recorder.observeBackspace()
        await recorder.observeBackspace()
        await recorder.observeBackspace()
        await recorder.observeKeyboardText("he ", startedAt: start.addingTimeInterval(0.8), endedAt: start.addingTimeInterval(1.0))
        await recorder.flush()

        let words = try await library.dailyWordUsage(days: 1, limit: 10)
        XCTAssertEqual(words.map(\.word), ["the"])
    }

    func testUsageRecorderDeleteWordDiscardsTheFinishedWord() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let start = Date()

        await recorder.observeKeyboardText("oops ", startedAt: start, endedAt: start.addingTimeInterval(0.4))
        await recorder.observeDeleteWord()
        await recorder.observeKeyboardText("fine ", startedAt: start.addingTimeInterval(0.6), endedAt: start.addingTimeInterval(0.9))
        await recorder.flush()

        let words = try await library.dailyWordUsage(days: 1, limit: 10)
        XCTAssertEqual(words.map(\.word), ["fine"])
    }

    func testUsageRecorderDoesNotTreatManualTypingAfterAChordAsAChordBurst() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let start = Date()

        await recorder.observeKeyboardText("go", source: .m4g, startedAt: start, endedAt: start.addingTimeInterval(0.004))
        await recorder.observeKeyboardText("i", source: .m4g, startedAt: start.addingTimeInterval(0.2), endedAt: start.addingTimeInterval(0.2))
        await recorder.observeKeyboardText("n", source: .m4g, startedAt: start.addingTimeInterval(0.3), endedAt: start.addingTimeInterval(0.3))
        await recorder.observeKeyboardText("g", source: .m4g, startedAt: start.addingTimeInterval(0.4), endedAt: start.addingTimeInterval(0.4))
        await recorder.flush()

        let words = try await library.dailyWordUsage(days: 1, limit: 10)
        XCTAssertEqual(words.first?.word, "going")
        XCTAssertEqual(words.first?.source, .m4gTyping)
    }

    func testSoftwareChordPhraseRecordsIndividualMultilingualWords() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let recorder = TypingRecorder(libraryService: library)
        let chord = ChordEntry(
            inputKeys: ["h", "m"],
            output: "Hello مَرْحَبًا",
            profile: .ansiQwerty,
            deploymentTarget: .software,
            source: "test"
        )

        await recorder.recordSoftwareChord(chord, startedAt: .now, endedAt: .now)

        let words = try await library.wordStats(limit: 10)
        XCTAssertTrue(words.contains { $0.word == "hello" && $0.language == .english })
        XCTAssertTrue(words.contains { $0.word == "مرحبا" && $0.language == .arabic })
        XCTAssertFalse(words.contains { $0.word == "hello مرحبا" })
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
