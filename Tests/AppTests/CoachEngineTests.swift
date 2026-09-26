import Engine
import Foundation
import Library
import XCTest
@testable import App

final class CoachEngineTests: XCTestCase {
    private let snapshot = CoachingSnapshot(
        chordInputs: ["exit": ["i", "x"], "the": ["e", "t"]],
        typoTargets: ["hte": "the"],
        goalWords: ["the"]
    )

    private func word(_ text: String, _ source: UsageSource = .keyboard) -> RecordedWord {
        RecordedWord(word: text, source: source, avgMs: 600, language: .english)
    }

    func testNudgesAForgottenChordThenRespectsGapAndCooldown() {
        var engine = CoachEngine()
        let start = Date()
        let settings = CoachSettings()

        let first = engine.nudge(for: word("exit"), handCountToday: 3, snapshot: snapshot, suggestions: [:], settings: settings, now: start)
        XCTAssertEqual(first?.kind, .forgotten)
        XCTAssertEqual(first?.input, ["i", "x"])

        // Too soon after the last hint.
        XCTAssertNil(engine.nudge(for: word("the"), handCountToday: 1, snapshot: snapshot, suggestions: [:], settings: settings, now: start.addingTimeInterval(5)))
        // Same word again within its cooldown.
        XCTAssertNil(engine.nudge(for: word("exit"), handCountToday: 4, snapshot: snapshot, suggestions: [:], settings: settings, now: start.addingTimeInterval(60)))
        // A different word after the gap is fine.
        XCTAssertNotNil(engine.nudge(for: word("the"), handCountToday: 2, snapshot: snapshot, suggestions: [:], settings: settings, now: start.addingTimeInterval(60)))
    }

    func testTypoAndSuggestionNudges() {
        var engine = CoachEngine()
        let start = Date()
        let settings = CoachSettings()

        let typo = engine.nudge(for: word("hte"), handCountToday: 1, snapshot: snapshot, suggestions: [:], settings: settings, now: start)
        XCTAssertEqual(typo?.kind, .typo(intended: "the"))
        XCTAssertEqual(typo?.title, "hte → the")

        let tooEarly = engine.nudge(for: word("gazebo"), handCountToday: 2, snapshot: snapshot, suggestions: ["gazebo": ["g", "z", "b"]], settings: settings, now: start.addingTimeInterval(30))
        XCTAssertNil(tooEarly)
        let suggestion = engine.nudge(for: word("gazebo"), handCountToday: 3, snapshot: snapshot, suggestions: ["gazebo": ["g", "z", "b"]], settings: settings, now: start.addingTimeInterval(60))
        XCTAssertEqual(suggestion?.kind, .suggestion(candidate: ["g", "z", "b"]))
    }

    func testRespectsSettingsAndIgnoresChordedWords() {
        var engine = CoachEngine()
        var settings = CoachSettings()
        XCTAssertNil(engine.nudge(for: word("exit", .m4gHIDConfirmed), handCountToday: 1, snapshot: snapshot, suggestions: [:], settings: settings))

        settings.m4gOnly = true
        XCTAssertNil(engine.nudge(for: word("exit", .keyboard), handCountToday: 1, snapshot: snapshot, suggestions: [:], settings: settings))
        XCTAssertNotNil(engine.nudge(for: word("exit", .m4gTyping), handCountToday: 1, snapshot: snapshot, suggestions: [:], settings: settings))

        settings.enabled = false
        XCTAssertNil(engine.nudge(for: word("the", .m4gTyping), handCountToday: 1, snapshot: snapshot, suggestions: [:], settings: settings, now: Date().addingTimeInterval(120)))
    }

    func testHourlyLimit() {
        var engine = CoachEngine()
        var settings = CoachSettings()
        settings.maxPerHour = 2
        let start = Date()
        let words = ["exit", "the", "hte"]
        var shown = 0
        for (index, text) in words.enumerated() {
            if engine.nudge(for: word(text), handCountToday: 1, snapshot: snapshot, suggestions: [:], settings: settings, now: start.addingTimeInterval(Double(index) * 30)) != nil {
                shown += 1
            }
        }
        XCTAssertEqual(shown, 2)
    }
}
