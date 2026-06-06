import Foundation
import XCTest
@testable import Device
@testable import Library

final class DeviceParserTests: XCTestCase {
    func testParseChordResponseRoundTripsFromUpsertCommand() throws {
        let record = DeviceChordRecord(inputKeys: ["t", "r", "h"], output: "there")
        let command = DeviceParser.upsertCommand(for: record)
        let parts = command.split(separator: " ")

        XCTAssertEqual(parts.count, 4)
        let response = "CML C1 0 \(parts[2]) \(parts[3])"

        let parsed = try XCTUnwrap(DeviceParser.parseChordResponse(response))
        XCTAssertEqual(
            ChordEntry.normalizeInputKeys(parsed.inputKeys),
            ChordEntry.normalizeInputKeys(record.inputKeys)
        )
        XCTAssertEqual(parsed.output, record.output)
    }

    func testBuildSyncPlanIncludesUpsertsAndDeletes() {
        let current = [
            DeviceChordRecord(inputKeys: ["t", "r", "h"], output: "there"),
            DeviceChordRecord(inputKeys: ["x", "s", "e"], output: "sex")
        ]
        let desired = [
            ChordEntry(
                inputKeys: ["t", "r", "h"],
                output: "there",
                profile: .cc2A1,
                deploymentTarget: .device,
                source: "FORGE M4G S3"
            ),
            ChordEntry(
                inputKeys: ["t", "r", "h", "g"],
                output: "heart",
                profile: .cc2A1,
                deploymentTarget: .device,
                source: "FORGE M4G S3"
            )
        ]

        let plan = DeviceSyncService.buildSyncPlan(current: current, desired: desired)
        XCTAssertEqual(plan.mutations.count, 2)

        let hasUpsert = plan.mutations.contains {
            if case .upsert(let record) = $0 {
                return record.inputKeys == ["t", "r", "h", "g"] && record.output == "heart"
            }
            return false
        }
        XCTAssertTrue(hasUpsert)

        let hasDelete = plan.mutations.contains {
            if case .delete(let record) = $0 {
                return record.inputKeys == ["x", "s", "e"] && record.output == "sex"
            }
            return false
        }
        XCTAssertTrue(hasDelete)
    }

    func testBuildAdditiveSyncPlanDoesNotDeleteHardwareOnlyChords() {
        let current = [
            DeviceChordRecord(inputKeys: ["t", "r", "h"], output: "there"),
            DeviceChordRecord(inputKeys: ["x", "s", "e"], output: "sex")
        ]
        let desired = [
            ChordEntry(
                inputKeys: ["t", "r", "h"],
                output: "there",
                profile: .cc2A1,
                deploymentTarget: .device,
                source: "FORGE M4G S3"
            )
        ]

        let plan = DeviceSyncService.buildAdditiveSyncPlan(current: current, desired: desired)
        XCTAssertTrue(plan.mutations.isEmpty)
        XCTAssertEqual(plan.deleteCount, 0)
    }

    func testBuildAdditiveSyncPlanUpsertsMissingDesiredChord() {
        let current = [
            DeviceChordRecord(inputKeys: ["t", "r", "h"], output: "there")
        ]
        let desired = [
            ChordEntry(
                inputKeys: ["t", "r", "h"],
                output: "there",
                profile: .cc2A1,
                deploymentTarget: .device,
                source: "FORGE M4G S3"
            ),
            ChordEntry(
                inputKeys: ["a", "dup", "n", "z"],
                output: "amazonzannaznnaanz",
                profile: .cc2A1,
                deploymentTarget: .device,
                source: "advisor"
            )
        ]

        let plan = DeviceSyncService.buildAdditiveSyncPlan(current: current, desired: desired)
        XCTAssertEqual(plan.mutations.count, 1)
        XCTAssertEqual(plan.upsertCount, 1)
        XCTAssertEqual(plan.deleteCount, 0)
        XCTAssertTrue(plan.mutations.contains {
            if case .upsert(let record) = $0 {
                return record.output == "amazonzannaznnaanz"
            }
            return false
        })
    }

    func testBuildAdditiveSyncPlanUpsertsChangedPhraseOnly() {
        let current = [
            DeviceChordRecord(inputKeys: ["t", "r", "h"], output: "there")
        ]
        let desired = [
            ChordEntry(
                inputKeys: ["t", "r", "h"],
                output: "their",
                profile: .cc2A1,
                deploymentTarget: .device,
                source: "FORGE M4G S3"
            )
        ]

        let plan = DeviceSyncService.buildAdditiveSyncPlan(current: current, desired: desired)
        XCTAssertEqual(plan.mutations.count, 1)
        XCTAssertEqual(plan.upsertCount, 1)
        XCTAssertEqual(plan.deleteCount, 0)
        XCTAssertTrue(plan.mutations.contains {
            if case .upsert(let record) = $0 {
                return record.inputKeys == ["t", "r", "h"] && record.output == "their"
            }
            return false
        })
    }

    func testBuildExplicitSyncPlanIncludesRequestedDelete() {
        let unwanted = DeviceChordRecord(inputKeys: ["a", "dup", "n", "z"], output: "amazonzannaznnaanz")
        let current = [
            DeviceChordRecord(inputKeys: ["t", "r", "h"], output: "there"),
            unwanted
        ]

        let plan = DeviceSyncService.buildExplicitSyncPlan(
            current: current,
            explicitMutations: [.delete(unwanted)]
        )

        XCTAssertEqual(plan.mutations.count, 1)
        XCTAssertEqual(plan.upsertCount, 0)
        XCTAssertEqual(plan.deleteCount, 1)
        XCTAssertTrue(plan.mutations.contains {
            if case .delete(let record) = $0 {
                return record.output == "amazonzannaznnaanz"
            }
            return false
        })
    }

    func testBuildExplicitSyncPlanSkipsAlreadyAppliedUpsert() {
        let current = [
            DeviceChordRecord(inputKeys: ["t", "r", "h"], output: "there")
        ]

        let plan = DeviceSyncService.buildExplicitSyncPlan(
            current: current,
            explicitMutations: [.upsert(DeviceChordRecord(inputKeys: ["t", "r", "h"], output: "there"))]
        )

        XCTAssertTrue(plan.mutations.isEmpty)
    }

    func testBuildExplicitSyncPlanKeepsLatestMutationForInput() {
        let first = DeviceChordRecord(inputKeys: ["t", "r", "h"], output: "there")
        let latest = DeviceChordRecord(inputKeys: ["t", "r", "h"], output: "their")

        let plan = DeviceSyncService.buildExplicitSyncPlan(
            current: [],
            explicitMutations: [.upsert(first), .upsert(latest)]
        )

        XCTAssertEqual(plan.mutations.count, 1)
        XCTAssertTrue(plan.mutations.contains {
            if case .upsert(let record) = $0 {
                return record.output == "their"
            }
            return false
        })
    }

    func testBuildSyncPlanUsesRawInputIdentityWhenVisibleInputMatches() {
        let currentRaw = RawChordRecord(
            inputActions: ActionCodec.normalizedChordActions([97, 98]),
            phraseActions: ActionCodec.phraseActions(forPlainText: "old")
        )
        let desiredRaw = RawChordRecord(
            inputActions: [123] + Array(repeating: 0, count: 9) + [97, 98],
            phraseActions: ActionCodec.phraseActions(forPlainText: "new")
        )
        XCTAssertEqual(currentRaw.display.inputTokens, desiredRaw.display.inputTokens)
        XCTAssertNotEqual(currentRaw.encodedInput, desiredRaw.encodedInput)

        let current = [
            DeviceChordRecord(
                inputKeys: currentRaw.display.inputTokens,
                output: currentRaw.display.plainOutput ?? "",
                rawInput: currentRaw.encodedInput,
                rawOutput: currentRaw.encodedPhrase,
                rawInputActions: currentRaw.inputActions,
                rawPhraseActions: currentRaw.phraseActions
            )
        ]
        let desired = [
            ChordEntry(
                inputKeys: desiredRaw.display.inputTokens,
                output: desiredRaw.display.plainOutput ?? "",
                rawInputActions: desiredRaw.inputActions,
                rawPhraseActions: desiredRaw.phraseActions,
                encodedInput: desiredRaw.encodedInput,
                encodedPhrase: desiredRaw.encodedPhrase,
                displayInput: desiredRaw.display.inputTokens,
                phraseTokens: desiredRaw.display.phraseTokens,
                actionFlags: desiredRaw.display.flags,
                plainOutput: desiredRaw.display.plainOutput,
                profile: .cc2A1,
                deploymentTarget: .device,
                source: "FORGE M4G S3"
            )
        ]

        let plan = DeviceSyncService.buildSyncPlan(current: current, desired: desired)
        XCTAssertEqual(plan.mutations.count, 2)
        XCTAssertTrue(plan.mutations.contains {
            if case .upsert(let record) = $0 {
                return record.rawInput == desiredRaw.encodedInput
            }
            return false
        })
        XCTAssertTrue(plan.mutations.contains {
            if case .delete(let record) = $0 {
                return record.rawInput == currentRaw.encodedInput
            }
            return false
        })
    }
}
