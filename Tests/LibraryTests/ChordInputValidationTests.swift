import XCTest
@testable import Library

final class ChordInputValidationTests: XCTestCase {
    func testIDupTokenInputIsValid() {
        let result = ChordInputValidator.validateM4GDeviceInput("i+dup", existingChords: [])

        XCTAssertTrue(result.isValid, result.errors.joined(separator: ", "))
        XCTAssertEqual(result.tokens, ["i", "dup"])
        XCTAssertNotNil(result.rawInputActions)
        XCTAssertNotNil(result.encodedInput)
    }

    func testUnsupportedTokenIsRejected() {
        let result = ChordInputValidator.validateM4GDeviceInput("nope!", existingChords: [])

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains("Unsupported M4G action in chord input."))
    }

    func testDuplicateTokenIsRejected() {
        let result = ChordInputValidator.validateM4GDeviceInput("i+i", existingChords: [])

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains("Duplicate physical key in chord input."))
    }

    func testCompactRepeatedCharacterCanRepresentDupForQuickCapture() {
        let result = ChordInputValidator.validateM4GDeviceInput(
            "mstt",
            existingChords: [],
            compactRepeatsUseDup: true
        )

        XCTAssertTrue(result.isValid, result.errors.joined(separator: ", "))
        XCTAssertEqual(result.tokens, ["m", "s", "t", "dup"])
    }

    func testExplicitRepeatedTokenStillRejectsDuplicatePhysicalKey() {
        let result = ChordInputValidator.validateM4GDeviceInput(
            "t+t",
            existingChords: [],
            compactRepeatsUseDup: true
        )

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains("Duplicate physical key in chord input."))
    }

    func testExactRawInputConflictIsRejectedUnlessReplacingSameChord() throws {
        let existing = ChordEntry(
            inputKeys: ["i", "dup"],
            output: "inside",
            profile: .cc2A1,
            deploymentTarget: .device,
            source: "test"
        )

        let conflict = ChordInputValidator.validateM4GDeviceInput("i+dup", existingChords: [existing])
        XCTAssertFalse(conflict.isValid)
        XCTAssertEqual(conflict.conflictingChordID, existing.id)
        XCTAssertTrue(conflict.errors.contains("Raw chord input already exists."))

        let replacement = ChordInputValidator.validateM4GDeviceInput(
            "i+dup",
            existingChords: [existing],
            replacingChordID: existing.id
        )
        XCTAssertTrue(replacement.isValid, replacement.errors.joined(separator: ", "))
    }

    func testMAndZSameLeftThumbLaneIsRejected() {
        let result = ChordInputValidator.validateM4GDeviceInput("m+z", existingChords: [])

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.contains("left thumb lane") })
    }
}
