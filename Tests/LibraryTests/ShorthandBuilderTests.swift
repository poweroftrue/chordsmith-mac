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

    func testOnlyTheLettersInTheirOrderMatch() {
        let catalog = ShorthandBuilder.build(chords: [chord(["a", "b", "t"], "about")], realWords: words)
        let matcher = ShorthandMatcher(catalog: catalog, realWords: words)
        XCTAssertEqual(matcher.match("abt")?.text, "about")
        XCTAssertNil(matcher.match("tba"), "another order is another token")
        XCTAssertNil(matcher.match("bat"))
        XCTAssertNil(matcher.match("ab"))
        XCTAssertNil(matcher.match("abtt"))
    }

    func testCaseFollowsWhatYouTyped() {
        let catalog = ShorthandBuilder.build(chords: [chord(["a", "b", "t"], "about")], realWords: words)
        let matcher = ShorthandMatcher(catalog: catalog, realWords: words)
        XCTAssertEqual(matcher.match("Abt")?.text, "About")
        XCTAssertEqual(matcher.match("ABT")?.text, "ABOUT")
    }

    func testWordsGetThreeOfTheirLettersEvenWhenTheChordHasTwo() throws {
        let catalog = ShorthandBuilder.build(chords: [chord(["w", "i"], "write"), chord(["AMBILEFT", "s"], "please")], realWords: words)
        let byWord = Dictionary(uniqueKeysWithValues: catalog.shorthands.map { ($0.word, $0) })
        XCTAssertEqual(byWord["write"]?.letters, "wrt")
        XCTAssertEqual(byWord["write"]?.kind, .newShortcut)
        XCTAssertEqual(byWord["please"]?.letters, "pls")
        XCTAssertTrue(catalog.shorthands.allSatisfy { $0.kind == .pressTogether || $0.letters.count >= 3 })
    }

    func testShortWordsArePressedTogetherOnly() throws {
        // Typing three letters for a four-letter word saves one key: not worth it.
        let catalog = ShorthandBuilder.build(chords: [chord(["h", "v"], "have"), chord(["e", "t"], "the")], realWords: words)
        let matcher = ShorthandMatcher(catalog: catalog, realWords: words)
        XCTAssertTrue(catalog.shorthands.allSatisfy { $0.kind == .pressTogether && $0.tokens.isEmpty })
        XCTAssertNil(matcher.match("hv"))
        XCTAssertEqual(matcher.matchChord("vh")?.text, "have")
        XCTAssertEqual(matcher.matchChord("te")?.text, "the")
    }

    func testChordsThatSpellTheWordOrAreNotTextAreSkipped() {
        let catalog = ShorthandBuilder.build(
            chords: [chord(["i", "t"], "it"), chord(["a", "LEFT_ALT"], "<LEFT_GUI>", flags: [.macro])],
            realWords: words
        )
        XCTAssertTrue(catalog.shorthands.isEmpty)
        XCTAssertEqual(Set(catalog.skipped.map(\.reason)), [.typeTheWord, .notText])
    }

    func testTheChordsOwnLettersWinWhenTheyReadWell() throws {
        let catalog = ShorthandBuilder.build(chords: [chord(["p", "d", "r"], "production")], realWords: words)
        let shorthand = try XCTUnwrap(catalog.shorthands.first)
        XCTAssertEqual(shorthand.letters, "prd")
        XCTAssertEqual(shorthand.kind, .sameKeys)
    }

    func testForgeOnlyKeysGetLettersToo() {
        let catalog = ShorthandBuilder.build(
            chords: [chord(["v", "AMBILEFT"], "eleven"), chord(["p", "AMBIRIGHT"], "eleventh")],
            realWords: words,
            usage: ["eleven": 10, "eleventh": 2]
        )
        let byWord = Dictionary(uniqueKeysWithValues: catalog.shorthands.map { ($0.word, $0) })
        XCTAssertEqual(byWord["eleven"]?.letters, "elv", "the word you write more picks first")
        XCTAssertEqual(byWord["eleventh"]?.letters.count, 3)
        XCTAssertNotEqual(byWord["eleventh"]?.letters, "elv")
    }

    func testRealWordsAndCommonTokensAreNeverPicked() throws {
        let real = words.union(ShorthandLetters.commonTokens).union(["wrt"])
        let catalog = ShorthandBuilder.build(chords: [chord(["w", "i"], "write"), chord(["s", "c"], "source")], realWords: real)
        let byWord = Dictionary(uniqueKeysWithValues: catalog.shorthands.map { ($0.word, $0) })
        let write = try XCTUnwrap(byWord["write"]?.letters)
        let source = try XCTUnwrap(byWord["source"]?.letters)
        XCTAssertNotEqual(write, "wrt")
        XCTAssertNotEqual(source, "src", "src is typed for real")
        XCTAssertEqual(write.first, "w")
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
        let about = chord(["a", "b", "t"], "about")
        let however = chord(["h", "o", "w"], "however")
        let catalog = ShorthandBuilder.build(
            chords: [about, however], realWords: words,
            overrides: [however.id: ShorthandOverride(chordID: however.id, letters: "how")]
        )
        XCTAssertNil(ShorthandMatcher(catalog: catalog, realWords: words).match("how"), "how is a word")
        let matcher = ShorthandMatcher(catalog: catalog, realWords: words, blocked: ["abt"], allowed: ["how"])
        XCTAssertNil(matcher.match("abt"))
        XCTAssertEqual(matcher.match("how")?.text, "however")
    }

    func testQuickLettersBeatSlowOnes() throws {
        let alternating = try XCTUnwrap(LaptopErgonomics.typingCost("fnc"))
        let oneFingerJump = try XCTUnwrap(LaptopErgonomics.typingCost("rvw"))
        let roll = try XCTUnwrap(LaptopErgonomics.typingCost("wer"))
        let changeOfDirection = try XCTUnwrap(LaptopErgonomics.typingCost("wre"))
        XCTAssertLessThan(alternating, oneFingerJump)
        XCTAssertLessThan(roll, changeOfDirection)
        XCTAssertNil(LaptopErgonomics.typingCost("a1"))
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
