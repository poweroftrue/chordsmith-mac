import Foundation
import SQLite3
import XCTest
@testable import Library

final class ImporterAndSuggestionTests: XCTestCase {
    func testLatestM4GChordFileRoundTripsAndImportsLosslessly() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["CHARAWORDER_M4G_EXPORT_FIXTURE"] else {
            throw XCTSkip("Set CHARAWORDER_M4G_EXPORT_FIXTURE to run the full M4G export round-trip fixture.")
        }
        let url = URL(fileURLWithPath: fixturePath)
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Latest M4G chord export is not available on this machine.")

        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(CharaChordFile.self, from: data)
        XCTAssertEqual(file.charaVersion, 1)
        XCTAssertEqual(file.type, "chords")
        XCTAssertEqual(file.chords.count, 2_177)
        XCTAssertEqual(file.chords.filter { !isLegacyParserPlainPhrase($0.phrase) }.count, 61)

        let imported = try CharaChordImporter(path: url).load(source: "M4G JSON")
        XCTAssertEqual(imported.count, file.chords.count)

        let exported = CharaChordExporter.file(from: imported)
        XCTAssertEqual(exported.chords, file.chords)

        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("charaworder.sqlite3"))
        let count = try await library.importCharaChordFile(at: url, source: "M4G JSON")
        XCTAssertEqual(count, 2_177)

        let stored = try await library.allChords()
        XCTAssertEqual(stored.count, 2_177)
        XCTAssertEqual(stored.filter { chord in
            guard let phrase = chord.rawPhraseActions else { return false }
            return !isLegacyParserPlainPhrase(phrase)
        }.count, 61)
    }

    func testBootstrapImportsDeviceLegacyAndNexusData() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let databaseURL = temp.url.appendingPathComponent("charaworder.sqlite3")
        let nexusURL = temp.url.appendingPathComponent("nexus.sqlite3")
        let freechorderURL = temp.url.appendingPathComponent("chords.yaml")

        try createNexusFixture(at: nexusURL)
        try createFreechorderFixture(at: freechorderURL)

        let library = try LibraryService(databaseURL: databaseURL)
        let source = DeviceSource(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            portPath: "/dev/cu.fake-m4g",
            deviceName: "FORGE M4G S3",
            firmware: "1.2.3",
            chordCount: 2163,
            isPrimary: true
        )
        let deviceChords = [
            DeviceChordRecord(inputKeys: ["t", "r", "h"], output: "there", rawInput: "ABC", rawOutput: "7468657265"),
            DeviceChordRecord(inputKeys: ["t", "r", "h", "g"], output: "heart", rawInput: "DEF", rawOutput: "6865617274")
        ]

        try await library.bootstrap(
            primarySource: source,
            deviceChords: deviceChords,
            nexusPath: nexusURL,
            freechorderPath: freechorderURL
        )

        let isBootstrapped = try await library.isBootstrapped()
        XCTAssertTrue(isBootstrapped)

        let sources = try await library.sources()
        XCTAssertEqual(sources, [source])

        let chords = try await library.allChords()
        XCTAssertEqual(chords.count, 3)

        let deviceChord = try XCTUnwrap(chords.first(where: { $0.output == "there" && $0.source == source.deviceName }))
        XCTAssertEqual(deviceChord.profile, .cc2A1)
        XCTAssertEqual(deviceChord.deploymentTarget, .device)
        XCTAssertTrue(deviceChord.enabled)

        let legacyChord = try XCTUnwrap(chords.first(where: { $0.source == "freechorder_review" }))
        XCTAssertEqual(legacyChord.output, "there")
        XCTAssertEqual(legacyChord.inputKeys, ["h", "r", "t"])
        XCTAssertEqual(legacyChord.profile, .ansiQwerty)
        XCTAssertEqual(legacyChord.deploymentTarget, .software)
        XCTAssertFalse(legacyChord.enabled)

        let words = try await library.wordStats(limit: 10)
        let errorWord = try XCTUnwrap(words.first(where: { $0.word == "error" }))
        XCTAssertEqual(errorWord.frequency, 7)
        XCTAssertEqual(errorWord.source, "aggregate")

        let chordStats = try await library.chordStats(limit: 10)
        let thereStat = try XCTUnwrap(chordStats.first(where: { $0.output == "there" }))
        XCTAssertEqual(thereStat.frequency, 3)

        let deviceSuggestions = try await library.listSuggestions(profile: .cc2A1, limit: 20)
        XCTAssertFalse(deviceSuggestions.isEmpty)
    }

    func testSuggestionEngineRejectsSameSwitchCandidatesOnCC2() {
        let engine = SuggestionEngine()
        let words = [
            WordStat(
                word: "error",
                frequency: 10,
                avgMs: 280,
                lastUsedAt: Date(timeIntervalSince1970: 1_000),
                source: "nexus"
            )
        ]

        let suggestions = engine.generateSuggestions(
            profile: .cc2A1,
            words: words,
            existingChords: [],
            bannedWords: [],
            bannedInputs: [],
            limit: 10
        )

        let suggestion = try? XCTUnwrap(suggestions.first(where: { $0.word == "error" }))
        XCTAssertNotNil(suggestion)
        let candidates = suggestion?.candidates ?? []
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertFalse(candidates.contains { Set($0.inputKeys).isSuperset(of: ["e", "r"]) })
    }

    func testEnglishMorphologyIndexFindsInflectionsAndDerivations() throws {
        let index = EnglishMorphologyIndex.bundled

        XCTAssertTrue(index.matches(for: "cities").contains { $0.lemma == "city" && $0.relation == .plural })
        XCTAssertTrue(index.matches(for: "children").contains { $0.lemma == "child" && $0.relation == .plural })
        XCTAssertTrue(index.matches(for: "created").contains { $0.lemma == "create" && $0.relation == .past })
        XCTAssertTrue(index.matches(for: "running").contains { $0.lemma == "run" && $0.relation == .gerund })
        XCTAssertTrue(index.matches(for: "inspiration").contains { $0.lemma == "inspire" && $0.relation == .ation && $0.suffixMarker == "t" })
        XCTAssertTrue(index.matches(for: "impressive").contains { $0.lemma == "impress" && $0.relation == .ive && $0.suffixMarker == "v" })
        XCTAssertTrue(index.matches(for: "unnecessary").contains { $0.lemma == "necessary" && $0.relation == .unPrefix && $0.suffixMarker == "u" })
    }

    func testWordAnchorAnalyzerRanksDistinctiveImpressiveAnchors() {
        let analysis = WordAnchorAnalyzer().analysis(for: "impressive")
        let strongest = analysis.strongestTokens(limit: 3)

        XCTAssertEqual(analysis.suffixMarker, "v")
        XCTAssertTrue(strongest.contains("v"))
        XCTAssertTrue(strongest.contains("p"))
        XCTAssertGreaterThan(analysis.weight(for: "v"), analysis.weight(for: "s"))
        XCTAssertGreaterThan(analysis.weight(for: "p"), analysis.weight(for: "m"))
    }

    func testM4GPhysicalModelMapsMAndZToSameLeftThumbLane() throws {
        let model = M4GPhysicalModel.defaultA1
        let m = try XCTUnwrap(model.bestPlacement(for: "m"))
        let z = try XCTUnwrap(model.bestPlacement(for: "z"))

        XCTAssertNotEqual(m.switchID, z.switchID)
        XCTAssertEqual(m.thumbLane, "left thumb lane")
        XCTAssertEqual(z.thumbLane, "left thumb lane")

        let reasons = model.hardConflictReasons(for: ["m", "z"])
        XCTAssertTrue(reasons.contains { $0.contains("left thumb lane") && $0.contains("m") && $0.contains("z") })
    }

    func testAdvisorRejectsAmazonMZLeftThumbConflict() {
        let engine = SuggestionEngine()
        let candidates = engine.adviseChord(
            for: "amazon",
            profile: .cc2A1,
            existingChords: [],
            limit: 20
        )

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertFalse(candidates.contains { Set($0.inputKeys).isSuperset(of: ["m", "z"]) })

        let rejected = engine.diagnoseRejectedCandidates(
            for: "amazon",
            profile: .cc2A1,
            existingChords: [],
            limit: 20
        )
        XCTAssertTrue(rejected.contains { candidate in
            Set(candidate.inputKeys).isSuperset(of: ["m", "z"]) &&
            candidate.hardFailures.contains { $0.contains("left thumb lane") }
        })
    }

    func testAdvisorExtendsExistingFamilyChordForInspiration() throws {
        let existing = ChordEntry(
            inputKeys: ["i", "n", "p", "r", "s"],
            output: "inspire",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )

        let engine = SuggestionEngine()
        let candidates = engine.adviseChord(
            for: "inspiration",
            profile: .cc2A1,
            existingChords: [existing],
            limit: 20
        )

        let familyIndex = try XCTUnwrap(candidates.firstIndex { candidate in
            Set(candidate.inputKeys) == Set(["i", "n", "p", "r", "s", "t"])
        })
        let familyCandidate = candidates[familyIndex]
        XCTAssertTrue(familyCandidate.softReasons.contains { $0.contains("Extends inspire") && $0.contains("-ation") })

        let dupIndex = candidates.firstIndex { candidate in
            Set(candidate.inputKeys) == Set(["dup", "n", "s", "r"])
        }
        if let dupIndex {
            XCTAssertLessThan(familyIndex, dupIndex)
        }
    }

    func testAdvisorExtendsExistingUnPrefixChordForUnnecessary() throws {
        let existing = ChordEntry(
            inputKeys: ["n", "e", "c"],
            output: "necessary",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )

        let candidates = SuggestionEngine().adviseChord(
            for: "unnecessary",
            profile: .cc2A1,
            existingChords: [existing],
            limit: 10
        )

        let familyCandidate = try XCTUnwrap(candidates.first { Set($0.inputKeys) == Set(["n", "e", "c", "u"]) })
        XCTAssertTrue(familyCandidate.hardFailures.isEmpty)
        XCTAssertTrue(familyCandidate.softReasons.contains { $0.contains("Extends necessary") && $0.contains("un-") })
        XCTAssertEqual(candidates.first?.inputKeys, familyCandidate.inputKeys)
    }

    func testAdvisorRejectsPhysicallyInvalidFamilyExtension() {
        let existing = ChordEntry(
            inputKeys: ["a"],
            output: "create",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )

        let engine = SuggestionEngine()
        let rejected = engine.diagnoseRejectedCandidates(
            for: "creation",
            profile: .cc2A1,
            existingChords: [existing],
            limit: 20
        )

        XCTAssertTrue(rejected.contains { candidate in
            Set(candidate.inputKeys) == Set(["a", "t"]) &&
            candidate.hardFailures.contains { $0.contains("Same-switch") }
        })
    }

    func testDupRightThumbLaneConflictsAreRejected() throws {
        let model = M4GPhysicalModel.defaultA1
        let dup = try XCTUnwrap(model.bestPlacement(for: "dup"))
        let f = try XCTUnwrap(model.bestPlacement(for: "f"))

        XCTAssertNotEqual(dup.switchID, f.switchID)
        XCTAssertEqual(dup.thumbLane, "right thumb lane")
        XCTAssertEqual(f.thumbLane, "right thumb lane")
        XCTAssertTrue(model.hardConflictReasons(for: ["dup", "f"]).contains { $0.contains("right thumb lane") })

        let engine = SuggestionEngine()
        let candidates = engine.adviseChord(
            for: "fool",
            profile: .cc2A1,
            existingChords: [],
            limit: 20
        )
        XCTAssertFalse(candidates.contains { Set($0.inputKeys).isSuperset(of: ["dup", "f"]) })

        let rejected = engine.diagnoseRejectedCandidates(
            for: "fool",
            profile: .cc2A1,
            existingChords: [],
            limit: 20
        )
        XCTAssertTrue(rejected.contains { candidate in
            Set(candidate.inputKeys).isSuperset(of: ["dup", "f"]) &&
            candidate.hardFailures.contains { $0.contains("right thumb lane") }
        })
    }

    func testAdvisorRejectsExistingRawInputIdentity() throws {
        let raw = try XCTUnwrap(ActionCodec.chordActions(forTokens: ["a", "m"]))
        let rawRecord = RawChordRecord(
            inputActions: raw,
            phraseActions: ActionCodec.phraseActions(forPlainText: "old")
        )
        let existing = ChordEntry(
            inputKeys: ["placeholder"],
            output: "old",
            rawInputActions: rawRecord.inputActions,
            rawPhraseActions: rawRecord.phraseActions,
            encodedInput: rawRecord.encodedInput,
            encodedPhrase: rawRecord.encodedPhrase,
            displayInput: ["a", "m"],
            phraseTokens: rawRecord.display.phraseTokens,
            actionFlags: rawRecord.display.flags,
            plainOutput: rawRecord.display.plainOutput,
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )

        let engine = SuggestionEngine()
        let candidates = engine.adviseChord(
            for: "am",
            profile: .cc2A1,
            existingChords: [existing],
            limit: 20
        )
        XCTAssertFalse(candidates.contains { Set($0.inputKeys) == Set(["a", "m"]) })

        let rejected = engine.diagnoseRejectedCandidates(
            for: "am",
            profile: .cc2A1,
            existingChords: [existing],
            limit: 20
        )
        XCTAssertTrue(rejected.contains { candidate in
            Set(candidate.inputKeys) == Set(["a", "m"]) &&
            candidate.hardFailures.contains("Raw chord input already exists.")
        })
    }

    func testAdvisorPrefersDupForRepeatedLetterWord() {
        let engine = SuggestionEngine()
        let candidates = engine.adviseChord(
            for: "letter",
            profile: .cc2A1,
            existingChords: [],
            limit: 10
        )

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates[0].inputKeys.contains("dup"))
        XCTAssertFalse(candidates.contains { Set($0.inputKeys).isSuperset(of: ["e", "r"]) })
    }

    func testAdvisorPrioritizesDistinctiveAnchorsForImpressive() {
        let engine = SuggestionEngine()
        let candidates = engine.adviseChord(
            for: "impressive",
            profile: .cc2A1,
            existingChords: [],
            limit: 10
        )

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.prefix(3).contains { Set($0.inputKeys).isSuperset(of: ["p", "v"]) })
        XCTAssertTrue(candidates.first?.softReasons.contains { $0.contains("Anchor coverage") && $0.contains("v") && $0.contains("p") } ?? false)
    }

    func testAdvisorUsesSmartLongFallbackForStarWhenCompactInputsAreUnavailable() {
        let existing = [
            ChordEntry(inputKeys: ["r", "s", "t"], output: "start", profile: .cc2A1, deploymentTarget: .device, source: "test"),
            ChordEntry(inputKeys: ["r", "t"], output: "rate", profile: .cc2A1, deploymentTarget: .device, source: "test"),
            ChordEntry(inputKeys: ["s", "t"], output: "state", profile: .cc2A1, deploymentTarget: .device, source: "test"),
            ChordEntry(inputKeys: ["r", "s"], output: "sure", profile: .cc2A1, deploymentTarget: .device, source: "test"),
            ChordEntry(inputKeys: ["a", "r"], output: "are", profile: .cc2A1, deploymentTarget: .device, source: "test"),
            ChordEntry(inputKeys: ["a", "s"], output: "as", profile: .cc2A1, deploymentTarget: .device, source: "test"),
            ChordEntry(inputKeys: ["a", "r", "s"], output: "rails", profile: .cc2A1, deploymentTarget: .device, source: "test")
        ]

        let candidates = SuggestionEngine().adviseChord(
            for: "star",
            profile: .cc2A1,
            existingChords: existing,
            limit: 20
        )

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.hardFailures.isEmpty })
        XCTAssertTrue(candidates.contains { candidate in
            Set(["r", "s", "t"]).isSubset(of: Set(candidate.inputKeys)) &&
            candidate.inputKeys.count >= 4 &&
            candidate.softReasons.contains { $0.contains("Long ergonomic fallback") }
        })
        XCTAssertFalse(candidates.contains { Set($0.inputKeys).isSuperset(of: ["a", "t"]) })
    }

    func testSmartLongFallbackDoesNotTriggerWhenCompactCoreIsValid() {
        let candidates = SuggestionEngine().adviseChord(
            for: "impressive",
            profile: .cc2A1,
            existingChords: [],
            limit: 20
        )

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertFalse(candidates.contains { candidate in
            candidate.softReasons.contains { $0.contains("Long ergonomic fallback") }
        })
    }

    func testStarredChordStyleCanBoostCandidatesWithoutBypassingValidation() {
        let starred = ChordEntry(
            inputKeys: ["i", "p", "r", "s", "v"],
            output: "pattern",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test",
            isStarred: true
        )

        let candidates = SuggestionEngine().adviseChord(
            for: "star",
            profile: .cc2A1,
            existingChords: [
                starred,
                ChordEntry(inputKeys: ["r", "s", "t"], output: "start", profile: .cc2A1, deploymentTarget: .device, source: "test")
            ],
            limit: 20
        )

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.hardFailures.isEmpty })
        XCTAssertTrue(candidates.contains { candidate in
            candidate.softReasons.contains { $0.contains("Matches starred chord style") }
        })
    }

    func testAdvisorRejectsPhysicallyInvalidImpressiveAnchorCombination() {
        let engine = SuggestionEngine()
        let rejected = engine.diagnoseRejectedCandidates(
            for: "impressive",
            profile: .cc2A1,
            existingChords: [],
            limit: 50
        )

        XCTAssertTrue(rejected.contains { candidate in
            Set(candidate.inputKeys).isSuperset(of: ["m", "v"]) &&
            candidate.hardFailures.contains { $0.contains("Same-switch") || $0.contains("left thumb lane") }
        })
    }

    func testChordFeedbackStarPersistsLocally() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("charaworder.sqlite3"))
        let chord = ChordEntry(
            inputKeys: ["i", "p", "r", "s", "v"],
            output: "impressive",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )
        try await library.upsertChord(chord)

        try await library.setChordStarred(id: chord.id, starred: true)
        let starredFeedback = try await library.chordFeedback(id: chord.id)
        let starredChord = try await library.allChords().first
        XCTAssertTrue(starredFeedback?.starred ?? false)
        XCTAssertEqual(starredChord?.isStarred, true)

        try await library.setChordStarred(id: chord.id, starred: false)
        let unstarredFeedback = try await library.chordFeedback(id: chord.id)
        let unstarredChord = try await library.allChords().first
        XCTAssertFalse(unstarredFeedback?.starred ?? true)
        XCTAssertEqual(unstarredChord?.isStarred, false)
    }

    func testUpsertChordUpdatesExistingNormalizedInputSlot() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let library = try LibraryService(databaseURL: temp.url.appendingPathComponent("charaworder.sqlite3"))

        let original = ChordEntry(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            inputKeys: ["h", "r", "t"],
            output: "there",
            profile: .ansiQwerty,
            deploymentTarget: .software,
            source: "test",
            enabled: true
        )
        try await library.upsertChord(original)

        let replacement = ChordEntry(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            inputKeys: ["t", "r", "h"],
            output: "their",
            profile: .ansiQwerty,
            deploymentTarget: .software,
            source: "user",
            enabled: false
        )
        try await library.upsertChord(replacement)

        let chords = try await library.allChords()
        XCTAssertEqual(chords.count, 1)

        let stored = try XCTUnwrap(chords.first)
        XCTAssertEqual(stored.id, original.id)
        XCTAssertEqual(stored.normalizedInput, "h+r+t")
        XCTAssertEqual(stored.output, "their")
        XCTAssertEqual(stored.source, "user")
        XCTAssertFalse(stored.enabled)
    }
}

private func isLegacyParserPlainPhrase(_ actions: [Int]) -> Bool {
    actions.allSatisfy { action in
        action == 32 ||
        action == 39 ||
        action == 44 ||
        action == 45 ||
        action == 46 ||
        action == 47 ||
        action == 59 ||
        action == 61 ||
        action == 91 ||
        action == 92 ||
        action == 93 ||
        action == 96 ||
        (48...57 ~= action) ||
        (97...122 ~= action)
    }
}

private func createNexusFixture(at url: URL) throws {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    guard let db else {
        XCTFail("Failed to open nexus fixture database.")
        return
    }
    defer { sqlite3_close(db) }

    XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE freqlog (word TEXT, frequency INTEGER, avgspeed REAL, lastused REAL)", nil, nil, nil), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE chordlog (chord TEXT, frequency INTEGER, lastused REAL)", nil, nil, nil), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(db, "INSERT INTO freqlog VALUES ('error', 7, 0.21, 1710000000)", nil, nil, nil), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(db, "INSERT INTO chordlog VALUES ('there', 3, 1710000500)", nil, nil, nil), SQLITE_OK)
}

private func createFreechorderFixture(at url: URL) throws {
    let yaml = """
    chords:
    - id: legacy-there
      output_text: there
      input:
      - h
      - r
      - t
    """
    try yaml.write(to: url, atomically: true, encoding: .utf8)
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
