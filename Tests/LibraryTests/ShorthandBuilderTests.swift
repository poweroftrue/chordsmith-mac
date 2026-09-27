import Foundation
import XCTest
@testable import Library

final class ShorthandBuilderTests: XCTestCase {
    private func chord(_ keys: [String], _ output: String, flags: Set<ChordFlag> = []) -> ChordEntry {
        ChordEntry(inputKeys: keys, output: output, actionFlags: flags, profile: .cc2A1, deploymentTarget: .device, source: "test")
    }

    private let words: Set<String> = ["bat", "tab", "how", "who", "it", "at", "the"]

    func testChordLettersBecomeAShorthandInWordOrder() throws {
        let catalog = ShorthandBuilder.build(chords: [chord(["t", "b", "a"], "about")], realWords: words)
        let shorthand = try XCTUnwrap(catalog.shorthands.first)
        XCTAssertEqual(shorthand.letters, "abt")
        XCTAssertEqual(shorthand.kind, .sameKeys)
        XCTAssertEqual(shorthand.savedKeystrokes, 2)
    }

    func testAnyOrderMatchesButRealWordsNeverDo() {
        let catalog = ShorthandBuilder.build(chords: [chord(["a", "b", "t"], "about")], realWords: words)
        let matcher = ShorthandMatcher(catalog: catalog, realWords: words)
        XCTAssertEqual(matcher.match("abt")?.text, "about")
        XCTAssertEqual(matcher.match("tba")?.text, "about")
        XCTAssertNil(matcher.match("bat"), "bat is a word")
        XCTAssertNil(matcher.match("tab"), "tab is a word")
        XCTAssertNil(matcher.match("ab"))
        XCTAssertNil(matcher.match("abtt"))
    }

    func testCaseFollowsWhatYouTyped() {
        let catalog = ShorthandBuilder.build(chords: [chord(["a", "b", "t"], "about")], realWords: words)
        let matcher = ShorthandMatcher(catalog: catalog, realWords: words)
        XCTAssertEqual(matcher.match("Abt")?.text, "About")
        XCTAssertEqual(matcher.match("ABT")?.text, "ABOUT")
    }

    func testChordsThatSpellTheWordOrSaveNothingAreSkipped() {
        let catalog = ShorthandBuilder.build(
            chords: [chord(["i", "t"], "it"), chord(["a", "e"], "at"), chord(["a", "LEFT_ALT"], "<LEFT_GUI>", flags: [.macro])],
            realWords: words
        )
        XCTAssertTrue(catalog.shorthands.isEmpty)
        XCTAssertEqual(Set(catalog.skipped.map(\.reason)), [.typeTheWord, .noSavings, .notText])
    }

    func testDupBecomesADoubledLetter() throws {
        let catalog = ShorthandBuilder.build(chords: [chord(["t", "h", "DUP"], "that"), chord(["s", "e", "DUP"], "see")], realWords: words)
        let that = try XCTUnwrap(catalog.shorthands.first { $0.word == "that" })
        XCTAssertEqual(that.kind, .doubledLetter)
        XCTAssertEqual(that.letters, "thh")
        let matcher = ShorthandMatcher(catalog: catalog, realWords: words)
        XCTAssertEqual(matcher.match("tth")?.text, "that")
        XCTAssertNil(matcher.match("th"), "without the doubled letter it's a different chord")
        XCTAssertEqual(catalog.skipped.first { $0.output == "see" }?.reason, .typeTheWord)
    }

    func testForgeOnlyKeysGetNewLetters() {
        let catalog = ShorthandBuilder.build(
            chords: [chord(["v", "AMBILEFT"], "eleven"), chord(["p", "AMBIRIGHT"], "eleventh")],
            realWords: words
        )
        let byWord = Dictionary(uniqueKeysWithValues: catalog.shorthands.map { ($0.word, $0) })
        XCTAssertEqual(byWord["eleven"]?.letters, "elv")
        XCTAssertEqual(byWord["eleven"]?.kind, .newShortcut)
        XCTAssertEqual(byWord["eleventh"]?.letters, "elvn", "the shorter word gets the shorter letters")
    }

    func testWhenTheWordOrderIsARealWordAnotherOrderIsSuggested() throws {
        let catalog = ShorthandBuilder.build(chords: [chord(["h", "o", "w"], "however")], realWords: words)
        let shorthand = try XCTUnwrap(catalog.shorthands.first)
        XCTAssertEqual(shorthand.letters, "hwo")
        let matcher = ShorthandMatcher(catalog: catalog, realWords: words)
        XCTAssertNil(matcher.match("how"))
        XCTAssertNil(matcher.match("who"))
        XCTAssertEqual(matcher.match("hwo")?.text, "however")
    }

    func testYourLettersWinAndCanBeTurnedOff() throws {
        let about = chord(["a", "b", "t"], "about")
        let because = chord(["b", "c"], "because")
        let overrides = [
            about.id: ShorthandOverride(chordID: about.id, letters: "bcz"),
            because.id: ShorthandOverride(chordID: because.id, disabled: true)
        ]
        let catalog = ShorthandBuilder.build(chords: [about, because], realWords: words, overrides: overrides)
        XCTAssertEqual(catalog.shorthands.map(\.letters), ["bcz"])
        XCTAssertEqual(catalog.shorthands.first?.kind, .custom)
        XCTAssertEqual(catalog.skipped.first?.reason, .disabled)
    }

    func testBlockedAndAllowedTokens() {
        let catalog = ShorthandBuilder.build(chords: [chord(["a", "b", "t"], "about"), chord(["h", "o", "w"], "however")], realWords: words)
        let matcher = ShorthandMatcher(catalog: catalog, realWords: words, blocked: ["abt"], allowed: ["how"])
        XCTAssertNil(matcher.match("abt"))
        XCTAssertEqual(matcher.match("tba")?.text, "about", "only the order you undid is blocked")
        XCTAssertEqual(matcher.match("how")?.text, "however")
    }

    func testCommonShellAndChatTokensAreRealWords() {
        let catalog = ShorthandBuilder.build(chords: [chord(["l", "s"], "list")], realWords: ShorthandLetters.commonTokens)
        let matcher = ShorthandMatcher(catalog: catalog, realWords: ShorthandLetters.commonTokens)
        XCTAssertNil(matcher.match("ls"))
        XCTAssertEqual(matcher.match("sl")?.text, "list")
    }

    func testUndoingTwiceBlocksAToken() async throws {
        let temp = try ShorthandTempDirectory()
        defer { temp.remove() }
        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        let first = try await library.recordShorthandUndo(token: "Abt")
        let second = try await library.recordShorthandUndo(token: "abt")
        XCTAssertFalse(first)
        XCTAssertTrue(second)
        let states = try await library.shorthandTokenStates()
        XCTAssertEqual(states.first?.state, "blocked")
        let stats = try await library.shorthandStats()
        XCTAssertEqual(stats.today.undos, 2)
    }

    func testFrequentlyTypedTokensCountAsRealWords() async throws {
        let temp = try ShorthandTempDirectory()
        defer { temp.remove() }
        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))
        for _ in 0..<5 {
            try await library.recordWordUsage(word: "zqx", avgMs: 100, source: .keyboard, lastUsedAt: .now)
        }
        try await library.recordWordUsage(word: "qzv", avgMs: 100, source: .keyboard, lastUsedAt: .now)
        let real = try await library.shorthandRealWords(for: [])
        XCTAssertTrue(real.contains("zqx"))
        XCTAssertFalse(real.contains("qzv"))
    }
}

final class LaptopErgonomicsTests: XCTestCase {
    private func chord(_ keys: [String], _ output: String) -> ChordEntry {
        ChordEntry(inputKeys: keys, output: output, profile: .cc2A1, deploymentTarget: .device, source: "test")
    }

    func testKeysOnOneFingerCantBePressedTogether() {
        XCTAssertNil(LaptopErgonomics.cost(Array("wx")), "both left ring finger")
        XCTAssertNil(LaptopErgonomics.cost(Array("lo")), "both right ring finger")
        XCTAssertNil(LaptopErgonomics.cost(Array("tg")), "both left index finger")
        XCTAssertTrue(LaptopErgonomics.isComfortable(Array("te")))
        XCTAssertTrue(LaptopErgonomics.isComfortable(Array("dlm")))
        XCTAssertNil(LaptopErgonomics.cost(Array("abcde")), "five keys is too many")
    }

    func testComfortableChordsKeepTheirKeys() throws {
        let catalog = ShorthandBuilder.build(chords: [chord(["e", "t"], "the")], realWords: [])
        let the = try XCTUnwrap(catalog.shorthands.first)
        XCTAssertEqual(the.pressKeys, "te")
        XCTAssertFalse(the.pressAdjusted)
    }

    func testChordsThatShareAFingerGetEasierKeysFromTheirOwn() throws {
        let catalog = ShorthandBuilder.build(chords: [chord(["d", "l", "m", "o"], "model")], realWords: [])
        let model = try XCTUnwrap(catalog.shorthands.first)
        XCTAssertTrue(model.pressAdjusted)
        let keys = try XCTUnwrap(model.pressKeys)
        XCTAssertTrue(LaptopErgonomics.isComfortable(Array(keys)))
        XCTAssertTrue(Set(keys).isSubset(of: Set("dlmo")), "reuses keys you already know")
        XCTAssertEqual(ShorthandMatcher(catalog: catalog, realWords: []).matchChord(keys)?.text, "model")
    }

    func testFrequentWordsPickFirst() throws {
        // Both would like m+e; the word you write more gets it.
        let chords = [chord(["m", "h", "t"], "them"), chord(["m", "n", "e"], "menu")]
        let catalog = ShorthandBuilder.build(chords: chords, realWords: [], usage: ["them": 500, "menu": 3])
        let them = try XCTUnwrap(catalog.shorthands.first { $0.word == "them" })
        let menu = try XCTUnwrap(catalog.shorthands.first { $0.word == "menu" })
        XCTAssertNotNil(them.pressKeys)
        XCTAssertNotEqual(them.chordSignature, menu.chordSignature)
    }
}

private struct ShorthandTempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
