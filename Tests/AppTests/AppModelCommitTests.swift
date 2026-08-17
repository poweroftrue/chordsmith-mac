import Device
import Foundation
import Library
import XCTest
@testable import App

@MainActor
final class AppModelCommitTests: XCTestCase {
    func testDeviceAddCommitWritesDatabaseAndUpsertsDevice() async throws {
        let fixture = try AppModelFixture()
        await fixture.model.addChord(
            input: "t,r,h",
            output: "there",
            profile: .cc2A1,
            deploymentTarget: .device
        )

        await fixture.model.commitStagedChanges()

        let chords = try await fixture.library.allChords()
        XCTAssertEqual(chords.map(\.output), ["there"])
        XCTAssertTrue(fixture.model.stagedChanges.isEmpty)
        XCTAssertTrue(fixture.model.pendingDeviceMutations.isEmpty)
        XCTAssertEqual(fixture.device.appliedMutationBatches().count, 1)
        XCTAssertTrue(fixture.device.appliedMutationBatches()[0].contains {
            if case .upsert(let record) = $0 {
                return record.output == "there"
            }
            return false
        })
        XCTAssertEqual(fixture.model.statusText, "Committed and synced to M4G")
    }

    func testDeviceDeleteCommitWritesDatabaseAndDeletesDevice() async throws {
        let fixture = try AppModelFixture()
        let chord = ChordEntry(
            inputKeys: ["a", "dup", "n", "z"],
            output: "amazonzannaznnaanz",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "advisor"
        )
        try await fixture.library.upsertChord(chord)

        await fixture.model.deleteChord(chord)
        await fixture.model.commitStagedChanges()

        let chords = try await fixture.library.allChords()
        XCTAssertTrue(chords.isEmpty)
        XCTAssertTrue(fixture.model.stagedChanges.isEmpty)
        XCTAssertTrue(fixture.model.pendingDeviceMutations.isEmpty)
        XCTAssertTrue(fixture.device.appliedMutationBatches()[0].contains {
            if case .delete(let record) = $0 {
                return record.output == "amazonzannaznnaanz"
            }
            return false
        })
    }

    func testSoftwareOnlyCommitDoesNotWriteDevice() async throws {
        let fixture = try AppModelFixture()
        await fixture.model.addChord(
            input: "j,k",
            output: "jk",
            profile: .ansiQwerty,
            deploymentTarget: .software
        )

        await fixture.model.commitStagedChanges()

        let chords = try await fixture.library.allChords()
        XCTAssertEqual(chords.map(\.output), ["jk"])
        XCTAssertTrue(fixture.device.appliedMutationBatches().isEmpty)
        XCTAssertTrue(fixture.model.pendingDeviceMutations.isEmpty)
        XCTAssertEqual(fixture.model.statusText, "Staged changes committed")
    }

    func testStarringChordUpdatesLocalFeedbackOnly() async throws {
        let fixture = try AppModelFixture()
        let chord = ChordEntry(
            inputKeys: ["i", "p", "r", "s", "v"],
            output: "impressive",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )
        try await fixture.library.upsertChord(chord)
        await fixture.model.refresh()
        let loaded = try XCTUnwrap(fixture.model.chords.first)

        await fixture.model.toggleChordStarred(loaded)

        let storedChord = try await fixture.library.allChords().first
        XCTAssertEqual(storedChord?.isStarred, true)
        XCTAssertTrue(fixture.device.appliedMutationBatches().isEmpty)
        XCTAssertTrue(fixture.model.pendingDeviceMutations.isEmpty)
        XCTAssertTrue(fixture.model.stagedChanges.isEmpty)
    }

    func testAdvisorShowsExistingDeviceChordsAndSuggestionsWhenOutputAlreadyExists() async throws {
        let fixture = try AppModelFixture()
        try await fixture.library.upsertChord(
            ChordEntry(
                inputKeys: ["d", "w"],
                output: "window",
                profile: .cc2A1,
                deploymentTarget: .device,
                source: "test"
            )
        )
        try await fixture.library.upsertChord(
            ChordEntry(
                inputKeys: ["d", "i", "n", "s", "w"],
                output: "window",
                profile: .cc2A1,
                deploymentTarget: .device,
                source: "test"
            )
        )

        await fixture.model.adviseChord(for: "window")

        XCTAssertEqual(fixture.model.advisorExistingChords.map(\.normalizedInput), ["d+i+n+s+w", "d+w"])
        XCTAssertFalse(fixture.model.advisorCandidates.isEmpty)
        XCTAssertTrue(fixture.model.advisorCandidates.allSatisfy { $0.hardFailures.isEmpty })
        let suggestionNoun = fixture.model.advisorCandidates.count == 1 ? "suggestion" : "suggestions"
        XCTAssertEqual(
            fixture.model.statusText,
            "window already has 2 M4G chords; found \(fixture.model.advisorCandidates.count) more \(suggestionNoun)"
        )
    }

    func testAdvisorCommitsPDFWithOriginalCapitalization() async throws {
        let fixture = try AppModelFixture()

        await fixture.model.adviseChord(for: "PDF")
        let candidate = try XCTUnwrap(fixture.model.advisorCandidates.first)
        await fixture.model.acceptAdvisorCandidate(candidate, word: "PDF")

        XCTAssertEqual(fixture.model.stagedChanges.first?.chord.output, "PDF")
        await fixture.model.commitStagedChanges()

        let storedChords = try await fixture.library.allChords()
        let stored = try XCTUnwrap(storedChords.first)
        XCTAssertEqual(stored.output, "PDF")
        XCTAssertTrue(fixture.device.appliedMutationBatches().joined().contains { mutation in
            if case .upsert(let record) = mutation {
                return record.output == "PDF"
            }
            return false
        })
    }

    func testQuickAdvisorCandidatesDoNotMutateMainAdvisorState() async throws {
        let fixture = try AppModelFixture()
        let sentinelCandidate = Candidate(
            inputKeys: ["s", "t"],
            score: 42,
            hardFailures: [],
            softReasons: ["sentinel"]
        )
        let sentinelChord = ChordEntry(
            inputKeys: ["w", "n"],
            output: "window",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "sentinel"
        )
        fixture.model.advisorCandidates = [sentinelCandidate]
        fixture.model.advisorRejectedCandidates = [sentinelCandidate]
        fixture.model.advisorExistingChords = [sentinelChord]
        fixture.model.statusText = "Advisor untouched"

        let candidates = try await fixture.model.quickAdvisorCandidates(for: "amazon", limit: 10)

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertEqual(fixture.model.advisorCandidates, [sentinelCandidate])
        XCTAssertEqual(fixture.model.advisorRejectedCandidates, [sentinelCandidate])
        XCTAssertEqual(fixture.model.advisorExistingChords, [sentinelChord])
        XCTAssertEqual(fixture.model.statusText, "Advisor untouched")
    }

    func testQuickAdvisorCandidatesReturnAlternativesWhenOutputAlreadyExists() async throws {
        let fixture = try AppModelFixture()
        try await fixture.library.upsertChord(
            ChordEntry(
                inputKeys: ["d", "w"],
                output: "window",
                profile: .cc2A1,
                deploymentTarget: .device,
                source: "test"
            )
        )

        let candidates = try await fixture.model.quickAdvisorCandidates(for: "window", limit: 10)

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.hardFailures.isEmpty })
        XCTAssertFalse(candidates.contains { ChordEntry.normalizeInputKeys($0.inputKeys) == "d+w" })
    }

    func testQuickAdvisorCandidatesCanIncludeValidDupCandidateForRepeatedLetterWord() async throws {
        let fixture = try AppModelFixture()

        let candidates = try await fixture.model.quickAdvisorCandidates(for: "letter", limit: 50)

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.contains { $0.inputKeys.contains("dup") })
        XCTAssertFalse(candidates.contains { !$0.hardFailures.isEmpty })
    }

    func testQuickAdvisorCandidatesRejectMZLeftThumbLaneConflict() async throws {
        let fixture = try AppModelFixture()

        let candidates = try await fixture.model.quickAdvisorCandidates(for: "amazon", limit: 20)

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertFalse(candidates.contains { Set($0.inputKeys).isSuperset(of: ["m", "z"]) })
    }

    func testChordSearchRanksCompactInputMatchAboveLooseOutputMatches() {
        let uiChord = ChordEntry(
            inputKeys: ["i", "u"],
            output: "press_nextleft_shiftuirelease_nextleft_shift",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )
        let looseMatch = ChordEntry(
            inputKeys: ["c", "i", "k", "l", "q", "u", "y"],
            output: "quickly",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )

        let ranked = ChordSearch.ranked([looseMatch, uiChord], query: "ui", limit: 12)

        XCTAssertEqual(ranked.first?.normalizedInput, "i+u")
    }

    func testChordSearchIgnoresChordFillerTerm() {
        let uiChord = ChordEntry(
            inputKeys: ["i", "u"],
            output: "press_nextleft_shiftuirelease_nextleft_shift",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )

        let ranked = ChordSearch.ranked([uiChord], query: "UI chord", limit: 12)

        XCTAssertEqual(ranked.first?.normalizedInput, "i+u")
    }

    func testDeviceSyncFailureKeepsDatabaseAndQueuesPendingMutation() async throws {
        let fixture = try AppModelFixture()
        fixture.device.applyError = TestDeviceError.writeFailed
        await fixture.model.addChord(
            input: "h,r,t",
            output: "heart",
            profile: .cc2A1,
            deploymentTarget: .device
        )

        await fixture.model.commitStagedChanges()

        let chords = try await fixture.library.allChords()
        XCTAssertEqual(chords.map(\.output), ["heart"])
        XCTAssertTrue(fixture.model.stagedChanges.isEmpty)
        XCTAssertEqual(fixture.model.pendingDeviceMutations.count, 1)
        XCTAssertEqual(fixture.model.statusText, "Committed locally; M4G sync failed and is queued")
    }

    func testRetryDeviceSyncClearsPendingMutationsAfterSuccess() async throws {
        let fixture = try AppModelFixture()
        fixture.device.applyError = TestDeviceError.writeFailed
        await fixture.model.addChord(
            input: "h,r,t",
            output: "heart",
            profile: .cc2A1,
            deploymentTarget: .device
        )
        await fixture.model.commitStagedChanges()
        XCTAssertEqual(fixture.model.pendingDeviceMutations.count, 1)

        fixture.device.applyError = nil
        fixture.model.deviceSource = fixture.source
        await fixture.model.syncPrimaryDevice()

        XCTAssertTrue(fixture.model.pendingDeviceMutations.isEmpty)
        XCTAssertEqual(fixture.device.appliedMutationBatches().count, 2)
        XCTAssertEqual(fixture.model.statusText, "Queued M4G changes synced (1 upserted, 0 deleted)")
    }

    func testQuickDeviceUpsertWritesDatabaseAndUpsertsDevice() async throws {
        let fixture = try AppModelFixture()

        let succeeded = await fixture.model.quickCommitDeviceUpsert(
            input: "i+dup",
            output: "inside"
        )

        XCTAssertTrue(succeeded)
        let chords = try await fixture.library.allChords()
        XCTAssertEqual(chords.map(\.output), ["inside"])
        XCTAssertTrue(fixture.model.stagedChanges.isEmpty)
        XCTAssertTrue(fixture.model.pendingDeviceMutations.isEmpty)
        XCTAssertEqual(fixture.device.appliedMutationBatches().count, 1)
        XCTAssertTrue(fixture.device.appliedMutationBatches()[0].contains {
            if case .upsert(let record) = $0 {
                return record.output == "inside"
                    && ChordEntry.normalizeInputKeys(record.inputKeys) == "dup+i"
            }
            return false
        })
    }

    func testQuickDeviceDeleteWritesDatabaseAndDeletesDevice() async throws {
        let fixture = try AppModelFixture()
        let chord = ChordEntry(
            inputKeys: ["i", "dup"],
            output: "inside",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )
        try await fixture.library.upsertChord(chord)

        let succeeded = await fixture.model.quickCommitDeviceDelete(chord)

        XCTAssertTrue(succeeded)
        let chords = try await fixture.library.allChords()
        XCTAssertTrue(chords.isEmpty)
        XCTAssertEqual(fixture.device.appliedMutationBatches().count, 1)
        XCTAssertTrue(fixture.device.appliedMutationBatches()[0].contains {
            if case .delete(let record) = $0 {
                return record.output == "inside"
            }
            return false
        })
    }

    func testQuickDeviceEditChangingInputDeletesOldInputAndUpsertsNewInput() async throws {
        let fixture = try AppModelFixture()
        let chord = ChordEntry(
            inputKeys: ["i", "dup"],
            output: "inside",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )
        try await fixture.library.upsertChord(chord)

        let succeeded = await fixture.model.quickCommitDeviceUpsert(
            input: "t+r",
            output: "inside",
            replacing: chord
        )

        XCTAssertTrue(succeeded)
        let chords = try await fixture.library.allChords()
        XCTAssertEqual(chords.map(\.normalizedInput), ["r+t"])
        let batch = try XCTUnwrap(fixture.device.appliedMutationBatches().first)
        XCTAssertEqual(batch.count, 2)
        XCTAssertTrue(batch.contains {
            if case .delete(let record) = $0 {
                return ChordEntry.normalizeInputKeys(record.inputKeys) == "dup+i"
            }
            return false
        })
        XCTAssertTrue(batch.contains {
            if case .upsert(let record) = $0 {
                return ChordEntry.normalizeInputKeys(record.inputKeys) == "r+t"
            }
            return false
        })
    }

    func testQuickDeviceSyncFailureKeepsDatabaseAndQueuesPendingMutation() async throws {
        let fixture = try AppModelFixture()
        fixture.device.applyError = TestDeviceError.writeFailed

        let succeeded = await fixture.model.quickCommitDeviceUpsert(
            input: "i+dup",
            output: "inside"
        )

        XCTAssertTrue(succeeded)
        let chords = try await fixture.library.allChords()
        XCTAssertEqual(chords.map(\.output), ["inside"])
        XCTAssertTrue(fixture.model.stagedChanges.isEmpty)
        XCTAssertEqual(fixture.model.pendingDeviceMutations.count, 1)
        XCTAssertEqual(fixture.model.statusText, "Quick chord committed locally; M4G sync failed and is queued")
    }

    func testQuickCommitDoesNotCommitUnrelatedStagedChanges() async throws {
        let fixture = try AppModelFixture()
        await fixture.model.addChord(
            input: "j,k",
            output: "jk",
            profile: .ansiQwerty,
            deploymentTarget: .software
        )
        XCTAssertEqual(fixture.model.stagedChanges.count, 1)

        let succeeded = await fixture.model.quickCommitDeviceUpsert(
            input: "i+dup",
            output: "inside"
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(fixture.model.stagedChanges.count, 1)
        XCTAssertEqual(fixture.model.stagedChanges.first?.chord.output, "jk")
        let chords = try await fixture.library.allChords()
        XCTAssertEqual(chords.map(\.output), ["inside"])
    }

    func testQuickReplacementRefusesNonPlainActionChord() async throws {
        let fixture = try AppModelFixture()
        let inputActions = try XCTUnwrap(ActionCodec.chordActions(forTokens: ["i", "dup"]))
        let raw = RawChordRecord(
            inputActions: inputActions,
            phraseActions: [523, 97, 524]
        )
        let chord = ChordEntry(
            inputKeys: raw.display.inputTokens,
            output: raw.display.displayOutput,
            rawInputActions: raw.inputActions,
            rawPhraseActions: raw.phraseActions,
            encodedInput: raw.encodedInput,
            encodedPhrase: raw.encodedPhrase,
            displayInput: raw.display.inputTokens,
            phraseTokens: raw.display.phraseTokens,
            actionFlags: raw.display.flags,
            plainOutput: raw.display.plainOutput,
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )

        let succeeded = await fixture.model.quickCommitDeviceUpsert(
            input: "i+dup",
            output: "inside",
            replacing: chord
        )

        XCTAssertFalse(succeeded)
        XCTAssertTrue(fixture.device.appliedMutationBatches().isEmpty)
        XCTAssertEqual(fixture.model.statusText, "Quick edit rejected")
    }

    func testQuickActionDeviceUpsertEditsNonPlainMacroChord() async throws {
        let fixture = try AppModelFixture()
        let inputActions = try XCTUnwrap(ActionCodec.chordActions(forTokens: ["i", "u"]))
        let raw = RawChordRecord(
            inputActions: inputActions,
            phraseActions: [523, 513, 117, 105, 524, 513]
        )
        let chord = ChordEntry(
            inputKeys: raw.display.inputTokens,
            output: raw.display.displayOutput,
            rawInputActions: raw.inputActions,
            rawPhraseActions: raw.phraseActions,
            encodedInput: raw.encodedInput,
            encodedPhrase: raw.encodedPhrase,
            displayInput: raw.display.inputTokens,
            phraseTokens: raw.display.phraseTokens,
            actionFlags: raw.display.flags,
            plainOutput: raw.display.plainOutput,
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )
        try await fixture.library.upsertChord(chord)
        await fixture.model.refresh()
        fixture.model.deviceSource = fixture.source

        let editedPhrase = [523, 513, 117, 105, 33, 524, 513]
        let succeeded = await fixture.model.quickCommitDeviceActionUpsert(
            input: "i+u",
            phraseActions: editedPhrase,
            replacing: chord
        )

        XCTAssertTrue(succeeded)
        let storedChords = try await fixture.library.allChords()
        let stored = try XCTUnwrap(storedChords.first)
        XCTAssertEqual(stored.rawPhraseActions, editedPhrase)
        XCTAssertEqual(stored.phraseTokens, editedPhrase.map { ActionCatalog.token(for: $0) })
        let batch = try XCTUnwrap(fixture.device.appliedMutationBatches().first)
        XCTAssertEqual(batch.count, 1)
        XCTAssertTrue(batch.contains {
            if case .upsert(let record) = $0 {
                return record.rawPhraseActions == editedPhrase
                    && ChordEntry.normalizeInputKeys(record.inputKeys) == "i+u"
            }
            return false
        })
    }

    func testQuickActionDeviceUpsertChangingInputDeletesOldMacroInput() async throws {
        let fixture = try AppModelFixture()
        let inputActions = try XCTUnwrap(ActionCodec.chordActions(forTokens: ["i", "u"]))
        let raw = RawChordRecord(
            inputActions: inputActions,
            phraseActions: [523, 513, 117, 105, 524, 513]
        )
        let chord = ChordEntry(
            inputKeys: raw.display.inputTokens,
            output: raw.display.displayOutput,
            rawInputActions: raw.inputActions,
            rawPhraseActions: raw.phraseActions,
            encodedInput: raw.encodedInput,
            encodedPhrase: raw.encodedPhrase,
            displayInput: raw.display.inputTokens,
            phraseTokens: raw.display.phraseTokens,
            actionFlags: raw.display.flags,
            plainOutput: raw.display.plainOutput,
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )
        try await fixture.library.upsertChord(chord)
        await fixture.model.refresh()
        fixture.model.deviceSource = fixture.source

        let succeeded = await fixture.model.quickCommitDeviceActionUpsert(
            input: "u+dup",
            phraseActions: raw.phraseActions,
            replacing: chord
        )

        XCTAssertTrue(succeeded)
        let batch = try XCTUnwrap(fixture.device.appliedMutationBatches().first)
        XCTAssertEqual(batch.count, 2)
        XCTAssertTrue(batch.contains {
            if case .delete(let record) = $0 {
                return ChordEntry.normalizeInputKeys(record.inputKeys) == "i+u"
            }
            return false
        })
        XCTAssertTrue(batch.contains {
            if case .upsert(let record) = $0 {
                return ChordEntry.normalizeInputKeys(record.inputKeys) == "dup+u"
            }
            return false
        })
    }

    func testQuickActionDeviceUpsertRejectsEmptyPhraseActions() async throws {
        let fixture = try AppModelFixture()

        let succeeded = await fixture.model.quickCommitDeviceActionUpsert(
            input: "i+u",
            phraseActions: []
        )

        XCTAssertFalse(succeeded)
        XCTAssertTrue(fixture.device.appliedMutationBatches().isEmpty)
        XCTAssertEqual(fixture.model.statusText, "Quick chord action output rejected")
    }
}

private final class AppModelFixture {
    let tempDirectory: URL
    let library: LibraryService
    let device: FakeAppDeviceService
    let source: DeviceSource
    let model: AppModel

    @MainActor
    init() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        library = try LibraryService(databaseURL: tempDirectory.appendingPathComponent("chordsmith.sqlite3"))
        device = FakeAppDeviceService()
        source = DeviceSource(
            portPath: "/dev/cu.test",
            deviceName: "FORGE M4G S3",
            firmware: "2.1.1",
            chordCount: 0,
            isPrimary: true
        )
        model = AppModel(libraryService: library, deviceService: device)
        model.deviceSource = source
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}

private enum TestDeviceError: LocalizedError {
    case writeFailed

    var errorDescription: String? {
        "test write failed"
    }
}

private final class FakeAppDeviceService: AppDeviceService, @unchecked Sendable {
    var applyError: Error?
    private let lock = NSLock()
    private var batches: [[DeviceMutation]] = []

    func preferredPrimarySnapshot(progress: ((Int, Int) -> Void)?) throws -> (DeviceSource, [DeviceChordRecord])? {
        nil
    }

    func snapshot(path: String, expectedCount: Int?, progress: ((Int, Int) -> Void)?) throws -> [DeviceChordRecord] {
        []
    }

    func applyMutations(_ mutations: [DeviceMutation], to path: String) throws {
        lock.lock()
        batches.append(mutations)
        let error = applyError
        lock.unlock()

        if let error {
            throw error
        }
    }

    func appliedMutationBatches() -> [[DeviceMutation]] {
        lock.lock()
        defer { lock.unlock() }
        return batches
    }
}
