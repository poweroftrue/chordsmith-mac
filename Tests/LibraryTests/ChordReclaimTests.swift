import Foundation
import XCTest
@testable import Library

final class ChordReclaimTests: XCTestCase {
    private let old = Date().addingTimeInterval(-120 * 86_400)

    private func chord(_ keys: [String], _ output: String, created: Date? = nil) -> ChordEntry {
        ChordEntry(inputKeys: keys, output: output, profile: .cc2A1, deploymentTarget: .device, source: "test",
                   createdAt: created ?? old, updatedAt: created ?? old)
    }

    /// The engine's favourite keys for "funcy", held by "funnel", a word
    /// you never write.
    private var bestKeys: [String] {
        SuggestionEngine().adviseChord(for: "funcy", existingChords: [], usage: 90, limit: 1).first!.inputKeys
    }

    private func library(deadCreated: Date? = nil) -> [ChordEntry] {
        [chord(bestKeys, "funnel", created: deadCreated)]
    }

    private func usage(dead: Int = 0, days: Int = 60) -> SlotUsage {
        var uses = ["funnel": dead]
        for index in 0..<40 { uses["alive\(index)"] = 200 }
        return SlotUsage(uses: uses, historyDays: days)
    }

    func testBarelyUsedChordIsOfferedSecondAndMoves() throws {
        let candidates = SuggestionEngine().adviseChord(
            for: "funcy", existingChords: library(), usage: 90, slotUsage: usage(), limit: 10
        )
        let reclaimIndex = try XCTUnwrap(candidates.firstIndex { $0.reclaim != nil }, "expected an offer to take the best keys")
        XCTAssertEqual(reclaimIndex, 1, "offered, never first")
        let offer = candidates[reclaimIndex]
        XCTAssertEqual(Set(offer.inputKeys), Set(bestKeys))
        XCTAssertEqual(offer.reclaim?.output, "funnel")
        XCTAssertFalse(offer.reclaim?.movedKeys.isEmpty ?? true)
        XCTAssertNotEqual(Set(offer.reclaim?.movedKeys ?? []), Set(bestKeys))
        XCTAssertTrue(offer.softReasons.first?.contains("funnel") ?? false)
    }

    func testWordsYouUseKeepTheirChords() {
        // Written 10 times in 60 days: a word you use, even if in bursts.
        let candidates = SuggestionEngine().adviseChord(
            for: "funcy", existingChords: library(), usage: 90, slotUsage: usage(dead: 10), limit: 10
        )
        XCTAssertFalse(candidates.contains { $0.reclaim != nil })
    }

    func testNewChordsAndShortHistoryAreLeftAlone() {
        let recent = SuggestionEngine().adviseChord(
            for: "funcy", existingChords: library(deadCreated: Date()), usage: 90, slotUsage: usage(), limit: 10
        )
        XCTAssertFalse(recent.contains { $0.reclaim != nil }, "a chord you just added hasn't had its chance")
        let short = SuggestionEngine().adviseChord(
            for: "funcy", existingChords: library(), usage: 90, slotUsage: usage(days: 10), limit: 10
        )
        XCTAssertFalse(short.contains { $0.reclaim != nil }, "ten days of history can't show a chord is unused")
    }

    func testReclaimNeedsTheNewWordToMatterMore() {
        let candidates = SuggestionEngine().adviseChord(
            for: "funcy", existingChords: library(), usage: 1, slotUsage: usage(), limit: 10
        )
        XCTAssertFalse(candidates.contains { $0.reclaim != nil })
    }

    func testOldSuggestionsWithoutReclaimStillDecode() throws {
        let json = #"{"inputKeys":["a","b"],"score":1,"hardFailures":[],"softReasons":[]}"#
        let candidate = try JSONDecoder().decode(Candidate.self, from: Data(json.utf8))
        XCTAssertNil(candidate.reclaim)
    }
}
