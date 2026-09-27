import Foundation
import XCTest
@testable import Engine
@testable import Library

final class ShorthandTyperTests: XCTestCase {
    private let matcher: ShorthandMatcher = {
        let chords = [
            ChordEntry(inputKeys: ["a", "b", "t"], output: "about", profile: .cc2A1, deploymentTarget: .device, source: "test"),
            ChordEntry(inputKeys: ["c", "b"], output: "because", profile: .cc2A1, deploymentTarget: .device, source: "test")
        ]
        let words: Set<String> = ["bat", "tab", "hi", "com"]
        return ShorthandMatcher(catalog: ShorthandBuilder.build(chords: chords, realWords: words), realWords: words)
    }()

    private var clock: TimeInterval = 100

    /// Types `text` at a human pace and returns the last action.
    @discardableResult
    private func type(_ text: String, into typer: inout ShorthandTyper, options: ShorthandTyper.Options = .init(), gap: TimeInterval = 0.09) -> ShorthandTyper.Action {
        var last = ShorthandTyper.Action.pass
        for character in text {
            clock += gap
            let matcher = self.matcher
            last = typer.handle(.text(String(character), isRepeat: false, at: clock), options: options) { matcher.match($0) }
        }
        return last
    }

    private func key(_ key: ShorthandTyper.Key, _ typer: inout ShorthandTyper) -> ShorthandTyper.Action {
        let matcher = self.matcher
        return typer.handle(key) { matcher.match($0) }
    }

    func testLettersThenSpaceAreReplaced() {
        var typer = ShorthandTyper()
        guard case .replace(let replacement) = type("abt ", into: &typer) else { return XCTFail("expected a replacement") }
        XCTAssertEqual(replacement.deleteCount, 3)
        XCTAssertEqual(replacement.insert, "about ")
        XCTAssertEqual(replacement.savedKeystrokes, 2)
    }

    func testOtherKeysAlwaysPassThrough() {
        var typer = ShorthandTyper()
        for character in "abt" {
            clock += 0.1
            XCTAssertEqual(typer.handle(.text(String(character), isRepeat: false, at: clock)) { self.matcher.match($0) }, .pass)
        }
    }

    func testRealWordsAndPartsOfWordsStayAsTyped() {
        var typer = ShorthandTyper()
        XCTAssertEqual(type("bat ", into: &typer), .pass)
        XCTAssertEqual(type("x.abt ", into: &typer), .pass, "abt after a dot is the end of something else")
        XCTAssertEqual(type("zabt ", into: &typer), .pass)
    }

    func testBackspaceRightAfterPutsTheLettersBack() {
        var typer = ShorthandTyper()
        type("abt ", into: &typer)
        guard case .replace(let undo) = key(.backspace(isRepeat: false), &typer) else { return XCTFail("expected an undo") }
        XCTAssertEqual(undo.kind, .undo)
        XCTAssertEqual(undo.deleteCount, 6)
        XCTAssertEqual(undo.insert, "abt ")
        XCTAssertEqual(type("abt ", into: &typer), .pass, "undone letters stay as typed for the session")
    }

    func testBackspaceLaterIsJustABackspace() {
        var typer = ShorthandTyper()
        type("abt ", into: &typer)
        type("x", into: &typer)
        XCTAssertEqual(key(.backspace(isRepeat: false), &typer), .pass)
    }

    func testFixingALetterStillCounts() {
        var typer = ShorthandTyper()
        type("abx", into: &typer)
        XCTAssertEqual(key(.backspace(isRepeat: false), &typer), .pass)
        guard case .replace(let replacement) = type("t ", into: &typer) else { return XCTFail("expected a replacement") }
        XCTAssertEqual(replacement.deleteCount, 3)
    }

    func testBackspacingIntoEarlierTextIsNotAWordStart() {
        var typer = ShorthandTyper()
        type("hi ", into: &typer)
        _ = key(.backspace(isRepeat: false), &typer)
        XCTAssertEqual(type("abt ", into: &typer), .pass, "that would really be `hiabt`")
    }

    func testPunctuationTriggersAndKeepsThePunctuation() {
        var typer = ShorthandTyper()
        guard case .replace(let replacement) = type("bc,", into: &typer) else { return XCTFail("expected a replacement") }
        XCTAssertEqual(replacement.insert, "because,")
        var other = ShorthandTyper()
        XCTAssertEqual(type("bc,", into: &other, options: .init(expandOnPunctuation: false)), .pass)
    }

    func testMachineSpeedTypingIsIgnored() {
        var typer = ShorthandTyper()
        XCTAssertEqual(type("abt ", into: &typer, gap: 0.004), .pass)
    }

    func testHeldKeysAndBoundaries() {
        var typer = ShorthandTyper()
        type("ab", into: &typer)
        clock += 0.3
        _ = typer.handle(.text("b", isRepeat: true, at: clock)) { self.matcher.match($0) }
        XCTAssertEqual(type("t ", into: &typer), .pass)

        var afterReturn = ShorthandTyper()
        type("hello", into: &afterReturn)
        _ = key(.boundary, &afterReturn)
        guard case .replace = type("abt ", into: &afterReturn) else { return XCTFail("a new line starts a word") }
    }

    func testOpeningBracketStartsAWord() {
        var typer = ShorthandTyper()
        guard case .replace(let replacement) = type("(abt ", into: &typer) else { return XCTFail("expected a replacement") }
        XCTAssertEqual(replacement.insert, "about ")
    }
}

final class ShorthandRecorderTests: XCTestCase {
    private func makeRecorder() throws -> (UsageRecorder, LibraryService, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let library = try LibraryService(databaseURL: url.appendingPathComponent("chordsmith.sqlite3"))
        return (UsageRecorder(libraryService: library), library, url)
    }

    func testExpansionBeforeTheSpaceArrivesCountsTheWord() async throws {
        let (recorder, library, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        await recorder.observeKeyboardText("abt", startedAt: start, endedAt: start.addingTimeInterval(0.3))
        await recorder.observeShorthand(kind: .expand, typed: "abt", output: "about", trigger: " ")
        await recorder.observeKeyboardText(" ", startedAt: start.addingTimeInterval(0.4), endedAt: start.addingTimeInterval(0.4))
        await recorder.flush()
        let today = try await library.todayUsage(goalWords: [])
        XCTAssertEqual(today.shorthandWords, 1)
        XCTAssertEqual(today.handTypedWords, 0)
    }

    func testExpansionAfterTheSpaceArrivedCountsTheWord() async throws {
        let (recorder, library, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        await recorder.observeKeyboardText("abt ", startedAt: start, endedAt: start.addingTimeInterval(0.4))
        await recorder.observeShorthand(kind: .expand, typed: "abt", output: "about", trigger: " ")
        await recorder.flush()
        let today = try await library.todayUsage(goalWords: [])
        XCTAssertEqual(today.shorthandWords, 1)
        XCTAssertNil(today.handCounts["abt"])
    }

    func testUndoKeepsTheLettersEitherWay() async throws {
        let (recorder, library, url) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        // Backspace seen before the undo notice.
        await recorder.observeKeyboardText("abt ", startedAt: start, endedAt: start.addingTimeInterval(0.4))
        await recorder.observeShorthand(kind: .expand, typed: "abt", output: "about", trigger: " ")
        await recorder.observeBackspace()
        await recorder.observeShorthand(kind: .undo, typed: "abt", output: "about", trigger: " ")
        // Undo notice before its backspace.
        await recorder.observeKeyboardText("bc ", startedAt: start.addingTimeInterval(1), endedAt: start.addingTimeInterval(1.3))
        await recorder.observeShorthand(kind: .expand, typed: "bc", output: "because", trigger: " ")
        await recorder.observeShorthand(kind: .undo, typed: "bc", output: "because", trigger: " ")
        await recorder.observeBackspace()
        await recorder.observeKeyboardText("ok ", startedAt: start.addingTimeInterval(2), endedAt: start.addingTimeInterval(2.2))
        await recorder.flush()
        let today = try await library.todayUsage(goalWords: [])
        XCTAssertEqual(today.shorthandWords, 0)
        XCTAssertEqual(today.handCounts["abt"], 1)
        XCTAssertEqual(today.handCounts["bc"], 1)
        XCTAssertEqual(today.handCounts["ok"], 1)
    }
}

final class ShorthandEventTests: XCTestCase {
    private func keyEvent(_ keyCode: CGKeyCode, text: String? = nil, flags: CGEventFlags = [], isRepeat: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        event.flags = flags
        if let text {
            let units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
        return event
    }

    func testClassifiesTypingEditingAndShortcuts() {
        guard case .text("a", false, _, 0) = ShorthandEngine.classify(keyEvent(0, text: "a")) else { return XCTFail("letter") }
        guard case .text("A", false, _, 0) = ShorthandEngine.classify(keyEvent(0, text: "A", flags: .maskShift)) else { return XCTFail("shifted letter") }
        guard case .text(" ", true, _, 49) = ShorthandEngine.classify(keyEvent(49, text: " ", isRepeat: true)) else { return XCTFail("held space") }
        XCTAssertEqual(ShorthandEngine.classify(keyEvent(8, text: "c", flags: .maskCommand)), .boundary, "⌘C is a shortcut")
        XCTAssertEqual(ShorthandEngine.classify(keyEvent(49, text: " ", flags: .maskControl)), .boundary, "⌃Space switches input source")
        XCTAssertEqual(ShorthandEngine.classify(keyEvent(51)), .backspace(isRepeat: false))
        XCTAssertEqual(ShorthandEngine.classify(keyEvent(51, flags: .maskAlternate)), .deleteWord)
        XCTAssertEqual(ShorthandEngine.classify(keyEvent(36, text: "\r")), .boundary)
        XCTAssertEqual(ShorthandEngine.classify(keyEvent(123, text: "\u{F702}")), .boundary)
        XCTAssertEqual(ShorthandEngine.classify(keyEvent(48, text: "\t")), .boundary)
    }

    @MainActor
    func testKeyMapFindsRealKeyCodes() throws {
        let map = ShorthandEngine.currentKeyMap()
        try XCTSkipIf(map.isEmpty, "no keyboard layout available")
        XCTAssertEqual(map[" "]?.keyCode, 49)
        XCTAssertEqual(map["A"]?.shift, true)
        XCTAssertEqual(map["a"]?.shift, false)
        XCTAssertEqual(map["a"]?.keyCode, map["A"]?.keyCode)
    }
}


final class MashedChordTests: XCTestCase {
    private let matcher: ShorthandMatcher = {
        let chords = [
            ChordEntry(inputKeys: ["a", "b", "t"], output: "about", profile: .cc2A1, deploymentTarget: .device, source: "test"),
            ChordEntry(inputKeys: ["o", "n"], output: "only", profile: .cc2A1, deploymentTarget: .device, source: "test")
        ]
        let words: Set<String> = ["bat", "tab", "on", "no"]
        return ShorthandMatcher(catalog: ShorthandBuilder.build(chords: chords, realWords: words), realWords: words)
    }()
    private let codes: [Character: UInt16] = ["a": 0, "b": 11, "t": 17, "o": 31, "n": 45, "x": 7, " ": 49]

    private func send(_ key: ShorthandTyper.Key, _ typer: inout ShorthandTyper, mash: Bool = true) -> ShorthandTyper.Action {
        let matcher = self.matcher
        return typer.handle(
            key,
            options: .init(mashChords: mash),
            match: { matcher.match($0) },
            chordMatch: { matcher.matchChord($0) },
            isRealWord: { matcher.isRealWord($0) }
        )
    }

    /// Presses `keys` at the given times (seconds), then releases them at
    /// the release times, returning the action of the last event.
    @discardableResult
    private func mash(_ keys: String, down: [Double], up: [Double], _ typer: inout ShorthandTyper, mash: Bool = true) -> ShorthandTyper.Action {
        var events: [(Double, ShorthandTyper.Key)] = []
        for (index, character) in keys.enumerated() {
            let code = codes[character]!
            events.append((down[index], .text(String(character), isRepeat: false, at: down[index], keyCode: code)))
            events.append((up[index], .keyUp(keyCode: code, at: up[index])))
        }
        var last = ShorthandTyper.Action.pass
        for (_, key) in events.sorted(by: { $0.0 < $1.0 }) {
            last = send(key, &typer, mash: mash)
        }
        return last
    }

    func testKeysPressedTogetherBecomeTheWordWithASpace() {
        var typer = ShorthandTyper()
        guard case .replace(let chord) = mash("abt", down: [0, 0.012, 0.025], up: [0.11, 0.12, 0.125], &typer) else {
            return XCTFail("expected a chord")
        }
        XCTAssertEqual(chord.kind, .chord)
        XCTAssertEqual(chord.deleteCount, 3)
        XCTAssertEqual(chord.insert, "about ")
        XCTAssertEqual(typer.lastChordAttempt?.matched, true)
    }

    func testRolledTypingIsNeverAChord() {
        var typer = ShorthandTyper()
        // Each key let go before the next goes down.
        XCTAssertEqual(mash("abt", down: [0, 0.09, 0.18], up: [0.07, 0.16, 0.25], &typer), .pass)
        // Fast rolling with overlap: a new key goes down after one was let go.
        var fast = ShorthandTyper()
        XCTAssertEqual(mash("abt", down: [0, 0.05, 0.1], up: [0.08, 0.13, 0.17], &fast), .pass)
        // Everything down at once but pressed slowly, as in a lazy roll.
        var slow = ShorthandTyper()
        XCTAssertEqual(mash("abt", down: [0, 0.07, 0.14], up: [0.2, 0.21, 0.22], &slow), .pass)
    }

    func testRealWordsNeedADeliberatePress() {
        var loose = ShorthandTyper()
        XCTAssertEqual(mash("on", down: [0, 0.035], up: [0.09, 0.1], &loose), .pass, "`on` rolled quickly stays `on`")
        var tight = ShorthandTyper()
        guard case .replace(let chord) = mash("on", down: [0, 0.01], up: [0.1, 0.11], &tight) else {
            return XCTFail("a firm press is a chord")
        }
        XCTAssertEqual(chord.insert, "only ")
    }

    func testSpaceAfterAChordIsDroppedAndPunctuationTucksIn() {
        var typer = ShorthandTyper()
        mash("abt", down: [0, 0.01, 0.02], up: [0.1, 0.1, 0.11], &typer)
        XCTAssertEqual(send(.text(" ", isRepeat: false, at: 0.3, keyCode: 49), &typer), .swallow)

        var other = ShorthandTyper()
        mash("abt", down: [0, 0.01, 0.02], up: [0.1, 0.1, 0.11], &other)
        guard case .replace(let edit) = send(.text(",", isRepeat: false, at: 0.3, keyCode: 43), &other) else {
            return XCTFail("expected the comma to replace the space")
        }
        XCTAssertEqual(edit.deleteCount, 1)
        XCTAssertEqual(edit.insert, ", ")
    }

    func testBackspaceUndoesAChord() {
        var typer = ShorthandTyper()
        mash("abt", down: [0, 0.01, 0.02], up: [0.1, 0.1, 0.11], &typer)
        guard case .replace(let undo) = send(.backspace(isRepeat: false), &typer) else { return XCTFail("expected undo") }
        XCTAssertEqual(undo.deleteCount, 6)
        XCTAssertEqual(undo.insert, "abt")
    }

    func testHoldingAChordDoesNotRepeatLetters() {
        var typer = ShorthandTyper()
        _ = send(.text("a", isRepeat: false, at: 0, keyCode: 0), &typer)
        _ = send(.text("b", isRepeat: false, at: 0.01, keyCode: 11), &typer)
        XCTAssertEqual(send(.text("b", isRepeat: true, at: 0.5, keyCode: 11), &typer), .swallow)
    }

    func testOnlyAtTheStartOfAWordAndOnlyWhenEnabled() {
        var typer = ShorthandTyper()
        _ = send(.text("x", isRepeat: false, at: 0, keyCode: 7), &typer)
        _ = send(.keyUp(keyCode: 7, at: 0.05), &typer)
        XCTAssertEqual(mash("abt", down: [0.2, 0.21, 0.22], up: [0.3, 0.3, 0.31], &typer), .pass)

        var off = ShorthandTyper()
        XCTAssertEqual(mash("abt", down: [0, 0.01, 0.02], up: [0.1, 0.1, 0.11], &off, mash: false), .pass)
    }
}
