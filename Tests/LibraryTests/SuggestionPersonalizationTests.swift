import Foundation
import XCTest
@testable import Library

final class SuggestionPersonalizationTests: XCTestCase {
    private func chord(_ keys: [String], _ output: String) -> ChordEntry {
        ChordEntry(inputKeys: keys, output: output, profile: .cc2A1, deploymentTarget: .device, source: "test")
    }

    /// A library where every chord starts with the word's first letter.
    private var firstLetterLibrary: [ChordEntry] {
        let words = ["river", "garden", "window", "yellow", "silver", "bottle", "candle", "forest", "island", "jacket",
                     "kitten", "lemon", "marble", "needle", "orange", "pencil", "rabbit", "saddle", "turtle", "velvet",
                     "wallet", "zipper", "anchor", "basket", "copper", "dragon", "engine", "falcon", "goblet", "hammer"]
        return words.map { word in
            let letters = Array(Set(word.map(String.init))).sorted()
            let first = String(word.first!)
            return chord([first] + letters.filter { $0 != first }.prefix(2), word)
        }
    }

    func testStyleModelLearnsFirstLetterHabit() {
        let style = LibraryStyleModel(existingChords: firstLetterLibrary)
        XCTAssertTrue(style.isTrained)
        XCTAssertEqual(style.firstLetterRate, 1, accuracy: 0.001)
        let with = style.score(keys: ["q", "u", "z"], word: "quiz", initials: ["q"])
        let without = style.score(keys: ["u", "i", "z"], word: "quiz", initials: ["q"])
        XCTAssertGreaterThan(with.score, without.score + 20)
        XCTAssertTrue(with.reasons.first?.contains("first letter") ?? false)
    }

    func testStyleModelStaysQuietWithFewChords() {
        let style = LibraryStyleModel(existingChords: Array(firstLetterLibrary.prefix(5)))
        XCTAssertFalse(style.isTrained)
        XCTAssertEqual(style.score(keys: ["u", "z"], word: "quiz", initials: ["q"]).score, 0)
    }

    func testFamilyMarkersAreLearnedFromYourPairs() {
        let library = [
            chord(["m", "o", "v"], "move"), chord(["m", "o", "v", "k"], "movement"),
            chord(["e", "j", "o", "y"], "enjoy")
        ]
        let family = FamilyMarkerModel(existingChords: library)
        XCTAssertEqual(family.markersBySuffix["ment"], ["k": 1])
        let extensions = family.extensions(for: "enjoyment")
        XCTAssertEqual(extensions.first?.base, "enjoy")
        XCTAssertEqual(extensions.first?.markers.first?.key, "k")
        XCTAssertEqual(extensions.first?.markers.first?.learned, true)
    }

    func testShortStemsWithLongTailsAreNotFamily() {
        let family = FamilyMarkerModel(existingChords: [chord(["f", "u", "n"], "fund")])
        XCTAssertTrue(family.extensions(for: "fundamentally").isEmpty)
    }

    func testAdvisorExtendsYourStemChord() throws {
        let library = firstLetterLibrary + [
            chord(["m", "o", "v"], "move"), chord(["m", "o", "v", "k"], "movement"),
            chord(["e", "j", "o", "y"], "enjoy")
        ]
        let candidates = SuggestionEngine().adviseChord(for: "enjoyment", existingChords: library, limit: 8)
        let family = try XCTUnwrap(candidates.first { $0.softReasons.first?.hasPrefix("Extends enjoy") ?? false })
        XCTAssertEqual(Set(family.inputKeys), ["e", "j", "o", "y", "k"])
        XCTAssertTrue(family.softReasons.first?.contains("like your other -ment words") ?? false)
    }

    func testNeighborsOneKeyAwayAreFound() {
        let index = ChordNeighborIndex(existingChords: [chord(["a", "b", "t"], "about"), chord(["d", "o"], "do")])
        XCTAssertEqual(index.neighbors(of: ["a", "b"], word: "quiz"), ["about"])
        XCTAssertEqual(index.neighbors(of: ["d", "o", "g"], word: "quiz"), ["do"])
        XCTAssertTrue(index.neighbors(of: ["a", "b"], word: "abou").isEmpty, "the same stem is intended")
    }

    func testTwoKeyChordsGoToFrequentWords() {
        let engine = SuggestionEngine()
        let rare = engine.adviseChord(for: "quiz", existingChords: [], usage: 2, limit: 20)
        let common = engine.adviseChord(for: "quiz", existingChords: [], usage: 900, limit: 20)
        let rareTwo = rare.first { $0.inputKeys.count == 2 }
        let commonTwo = common.first { $0.inputKeys.count == 2 }
        XCTAssertNotNil(rareTwo)
        XCTAssertNotNil(commonTwo)
        XCTAssertGreaterThan(commonTwo!.score, rareTwo!.score + 15)
        XCTAssertTrue(rareTwo!.softReasons.contains { $0.contains("scarce") })
    }

    func testPhrasesStartFromEachWordsFirstLetter() throws {
        let candidates = SuggestionEngine().adviseChord(for: "thank  you", existingChords: firstLetterLibrary, limit: 5)
        let best = try XCTUnwrap(candidates.first)
        XCTAssertTrue(best.inputKeys.contains("t"))
        XCTAssertTrue(best.inputKeys.contains("y"))
    }
}
