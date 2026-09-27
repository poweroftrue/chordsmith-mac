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
        guard case .text("a", false, _) = ShorthandEngine.classify(keyEvent(0, text: "a")) else { return XCTFail("letter") }
        guard case .text("A", false, _) = ShorthandEngine.classify(keyEvent(0, text: "A", flags: .maskShift)) else { return XCTFail("shifted letter") }
        guard case .text(" ", true, _) = ShorthandEngine.classify(keyEvent(49, text: " ", isRepeat: true)) else { return XCTFail("held space") }
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
