import Foundation
import XCTest
@testable import Library

final class GrowthPlannerTests: XCTestCase {
    private func usage(_ word: String, typed: Int, avgMs: Double = 800, chorded: Int = 0, language: WordLanguage = .english) -> WordSourceUsage {
        WordSourceUsage(
            word: word,
            language: language,
            typedFrequency: typed,
            keyboardFrequency: typed,
            chordedFrequency: chorded,
            typedAvgMs: avgMs,
            lastUsedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func deviceChord(_ keys: [String], _ output: String) -> ChordEntry {
        ChordEntry(inputKeys: keys, output: output, profile: .cc2A1, deploymentTarget: .device, source: "test")
    }

    func testPlanRanksByTimeLostAndSkipsChordedWords() {
        let plan = GrowthPlanner().plan(
            usage: [
                usage("the", typed: 500, avgMs: 250),
                usage("gazebo", typed: 50, avgMs: 900),
                usage("lantern", typed: 20, avgMs: 800)
            ],
            profile: .cc2A1,
            existingChords: [deviceChord(["t", "e"], "the")],
            bannedInputs: [],
            skippedWords: [],
            windowDays: 30,
            limit: 10
        )

        XCTAssertEqual(plan.items.map(\.word), ["gazebo", "lantern"])
        XCTAssertFalse(plan.items.contains { $0.word == "the" })
        XCTAssertGreaterThan(plan.uncoveredTimeShare, 0.3)
    }

    func testPlanSeparatesTyposOfChordedWords() {
        let plan = GrowthPlanner().plan(
            usage: [
                usage("the", typed: 500, avgMs: 250),
                usage("hte", typed: 40, avgMs: 220),
                usage("fare", typed: 30, avgMs: 900),
                usage("are", typed: 300, avgMs: 250)
            ],
            profile: .cc2A1,
            existingChords: [deviceChord(["t", "e"], "the"), deviceChord(["a", "r", "e"], "are")],
            bannedInputs: [],
            skippedWords: [],
            dictionary: ["fare", "the", "are"],
            windowDays: 30,
            limit: 10
        )

        XCTAssertEqual(plan.typos.map(\.typo), ["hte"])
        XCTAssertEqual(plan.typos.first?.intended, "the")
        XCTAssertEqual(plan.typos.first?.intendedChordInput, ["t", "e"])
        // `fare` is a real word, not a typo of `are`.
        XCTAssertEqual(plan.items.map(\.word), ["fare"])
    }

    func testPlanDropsCompletionFragmentsAndSkippedWords() {
        let plan = GrowthPlanner().plan(
            usage: [
                usage("screen", typed: 40),
                usage("scre", typed: 9, avgMs: 2_000),
                usage("walrus", typed: 30),
                usage("ok", typed: 90)
            ],
            profile: .cc2A1,
            existingChords: [deviceChord(["s", "c", "n"], "screen")],
            bannedInputs: [],
            skippedWords: ["walrus"],
            dictionary: ["screen"],
            windowDays: 30,
            limit: 10
        )

        XCTAssertTrue(plan.items.isEmpty, "\(plan.items.map(\.word))")
        XCTAssertEqual(plan.skippedWords, ["walrus"])
    }

    func testPlanLabelsInflectionsOfChordedWordsAsEndings() {
        let plan = GrowthPlanner().plan(
            usage: [usage("running", typed: 30, avgMs: 900)],
            profile: .cc2A1,
            existingChords: [deviceChord(["r", "u", "n"], "run")],
            bannedInputs: [],
            skippedWords: [],
            windowDays: 30,
            limit: 10
        )

        let item = try? XCTUnwrap(plan.items.first)
        XCTAssertEqual(item?.category, .ending)
        XCTAssertEqual(item?.baseWord, "run")
        XCTAssertEqual(Set(item?.candidates.first?.inputKeys ?? []), ["r", "u", "n", "g"])
    }

    func testPlanFirstCandidatesNeverCollideWithinTheBatch() {
        let words = ["products", "product", "producer", "production", "productive", "prods", "prod"]
        let plan = GrowthPlanner().plan(
            usage: words.enumerated().map { usage($0.element, typed: 50 - $0.offset, avgMs: 900) },
            profile: .cc2A1,
            existingChords: [],
            bannedInputs: [],
            skippedWords: [],
            windowDays: 30,
            limit: 20
        )

        let inputs = plan.items.compactMap { $0.candidates.first.map { ChordEntry.normalizeInputKeys($0.inputKeys) } }
        XCTAssertEqual(inputs.count, plan.items.count)
        XCTAssertEqual(Set(inputs).count, inputs.count, "\(inputs)")
    }

    func testPlanLeavesArabicOutButCountsIt() {
        let plan = GrowthPlanner().plan(
            usage: [usage("مرحبا", typed: 12, language: .arabic)],
            profile: .cc2A1,
            existingChords: [],
            bannedInputs: [],
            skippedWords: [],
            windowDays: 30,
            limit: 10
        )

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertEqual(plan.arabicWordCount, 1)
        XCTAssertEqual(plan.arabicOccurrences, 12)
    }

    private func usage(_ word: String, typed: Int, avgMs: Double = 800, completed: Int) -> WordSourceUsage {
        WordSourceUsage(
            word: word,
            language: .english,
            typedFrequency: typed,
            keyboardFrequency: typed,
            chordedFrequency: 0,
            typedAvgMs: avgMs,
            lastUsedAt: Date(timeIntervalSince1970: 1_000),
            completedFrequency: completed
        )
    }

    func testCompletionTargetsFollowChainsToTheFullWord() {
        let targets = GrowthPlanner.completionTargets(
            usage: [usage("zel", typed: 86), usage("zelv", typed: 101), usage("zelvora", typed: 54), usage("zelvo", typed: 17)],
            dictionary: []
        )
        XCTAssertEqual(targets["zel"], "zelvora")
        XCTAssertEqual(targets["zelv"], "zelvora")
        XCTAssertEqual(targets["zelvo"], "zelvora")
        XCTAssertNil(targets["zelvora"])
    }

    func testFoldMergesAliasesAndAutocompletedFragments() {
        let folded = GrowthPlanner.fold(
            [
                usage("zelvora", typed: 54, avgMs: 1_800),
                usage("zelv", typed: 100, avgMs: 1_300),
                usage("zel", typed: 10, avgMs: 1_200, completed: 8),
                usage("mini", typed: 70, avgMs: 900),
                usage("minimum", typed: 5, avgMs: 900)
            ],
            aliases: ["zelv": "zelvora"],
            dictionary: ["minimum"]
        )

        let zelvora = try? XCTUnwrap(folded.first { $0.word == "zelvora" })
        XCTAssertEqual(zelvora?.typedFrequency, 164)
        XCTAssertEqual(zelvora?.mergedWords, ["zel", "zelv"])
        XCTAssertEqual(zelvora?.completedFrequency, 8)
        XCTAssertFalse(folded.contains { $0.word == "zelv" || $0.word == "zel" })
        // No alias and no autocomplete evidence: `mini` stays a word.
        XCTAssertTrue(folded.contains { $0.word == "mini" })
    }

    func testPlanSuggestsMergingAFragmentAndFoldsMisspellingsOfUnchordedWords() {
        let plan = GrowthPlanner().plan(
            usage: [
                usage("zelv", typed: 101, avgMs: 1_300),
                usage("zelvora", typed: 54, avgMs: 1_800),
                usage("elvora", typed: 13, avgMs: 1_300)
            ],
            profile: .cc2A1,
            existingChords: [],
            bannedInputs: [],
            skippedWords: [],
            windowDays: 30,
            limit: 10
        )

        let zelv = try? XCTUnwrap(plan.items.first { $0.word == "zelv" })
        XCTAssertEqual(zelv?.possibleCompletionOf, "zelvora")
        let zelvora = try? XCTUnwrap(plan.items.first { $0.word == "zelvora" })
        XCTAssertEqual(zelvora?.frequency, 67)
        XCTAssertEqual(zelvora?.mergedWords, ["elvora"])
        XCTAssertFalse(plan.items.contains { $0.word == "elvora" })
    }

    func testWordAliasesPersistAndCompletionKeysAreCounted() async throws {
        let temp = try PlannerTemporaryDirectory()
        defer { temp.remove() }
        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))

        try await library.setWordAlias(["Zelv", "zel"], target: "Zelvora")
        let aliases = try await library.wordAliases()
        XCTAssertEqual(aliases, ["zelv": "zelvora", "zel": "zelvora"])

        try await library.recordWordUsage(word: "zelv", avgMs: 1_300, source: .keyboard, frequencyDelta: 4)
        try await library.recordCompletedWord("zelv")
        try await library.recordCompletedWord("zelv")
        let usage = try await library.wordSourceUsage(days: 1)
        XCTAssertEqual(usage.first { $0.word == "zelv" }?.completedFrequency, 2)

        try await library.setWordAlias(["zel"], target: nil)
        let remaining = try await library.wordAliases()
        XCTAssertEqual(remaining, ["zelv": "zelvora"])
    }

    func testCommaKeyIsKeptWhenPlusSeparatesTokens() {
        XCTAssertEqual(ChordInputValidator.tokens(from: ",+g+o"), [",", "g", "o"])
        XCTAssertEqual(ChordInputValidator.tokens(from: "t,h,e"), ["t", "h", "e"])
    }

    func testPracticeReportFindsForgottenChordsTyposAndNewChords() async throws {
        let temp = try PlannerTemporaryDirectory()
        defer { temp.remove() }
        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("chordsmith.sqlite3"))

        let exit = deviceChord(["i", "x"], "exit")
        let newChord = ChordEntry(inputKeys: ["h", "r", "m"], output: "gazebo", profile: .cc2A1, deploymentTarget: .device, source: "grow")
        try await library.upsertChord(exit)
        try await library.upsertChord(newChord)
        try await library.upsertChord(deviceChord(["t", "e"], "the"))
        try await library.recordWordUsage(word: "exit", avgMs: 700, source: .keyboard, frequencyDelta: 12)
        try await library.recordWordUsage(word: "exit", avgMs: 5, source: .m4gHIDConfirmed, frequencyDelta: 4)
        try await library.recordWordUsage(word: "the", avgMs: 200, source: .keyboard, frequencyDelta: 40)
        try await library.recordWordUsage(word: "hte", avgMs: 200, source: .keyboard, frequencyDelta: 6)

        let report = try await library.practiceReport(days: 7)

        let forgottenExit = try XCTUnwrap(report.forgotten.first { $0.word == "exit" })
        XCTAssertEqual(forgottenExit.typedFrequency, 12)
        XCTAssertEqual(forgottenExit.chordedFrequency, 4)
        XCTAssertEqual(forgottenExit.chordInputs, [["i", "x"]])
        XCTAssertEqual(report.typos.first?.typo, "hte")
        XCTAssertEqual(report.learning.map(\.word), ["gazebo"])
        XCTAssertEqual(report.chordedWords, 4)
        XCTAssertFalse(report.lacksM4GAttribution)

        try await library.setChordLearned(id: newChord.id, learned: true)
        let afterLearning = try await library.practiceReport(days: 7)
        XCTAssertTrue(afterLearning.learning.isEmpty)
        XCTAssertEqual(afterLearning.learnedCount, 1)
    }

    func testSkippedGrowthWordsPersist() async throws {
        let temp = try PlannerTemporaryDirectory()
        defer { temp.remove() }
        let url = temp.url.appendingPathComponent("chordsmith.sqlite3")
        let library = try LibraryService(databaseURL: url)

        try await library.setGrowthWordSkipped("Walrus", skipped: true)
        let reopened = try LibraryService(databaseURL: url)
        let skipped = try await reopened.skippedGrowthWords()
        XCTAssertEqual(skipped, ["walrus"])

        try await reopened.setGrowthWordSkipped("walrus", skipped: false)
        let cleared = try await reopened.skippedGrowthWords()
        XCTAssertTrue(cleared.isEmpty)
    }
}

private struct PlannerTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
