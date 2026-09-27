import Foundation

/// The time range a stats report covers. Long ranges bucket by month so
/// each bar stays readable, the way Health switches from days to months.
public enum StatsPeriod: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case week = "7D"
    case month = "30D"
    case quarter = "90D"
    case year = "12M"

    public var id: String { rawValue }

    public var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .year: return 365
        }
    }

    public var bucketsByMonth: Bool { self == .year }

    public var displayName: String {
        switch self {
        case .week: return "last 7 days"
        case .month: return "last 30 days"
        case .quarter: return "last 90 days"
        case .year: return "last 12 months"
        }
    }
}

/// Everything recorded in one day (or month, for the 12-month view).
public struct StatsBucket: Codable, Hashable, Sendable, Identifiable {
    public var id: Date { start }

    public let start: Date
    public var chordedWords = 0
    public var m4gTypedWords = 0
    public var keyboardWords = 0
    /// Typed while no Master Forge was connected: no chord was possible.
    public var awayWords = 0
    /// Replaced from a laptop shorthand (chord letters typed, then Space).
    public var shorthandWords = 0
    /// Chord outputs recorded, including multi-word phrases.
    public var chordsUsed = 0
    /// Uses of words that are almost certainly misspellings.
    public var typoWords = 0
    /// Word uses for which an M4G chord existed.
    public var coveredWords = 0
    /// Letters typed one at a time, and the time they took, per keyboard.
    public var keyboardLetters = 0
    public var keyboardMs = 0.0
    public var m4gLetters = 0
    public var m4gMs = 0.0
    /// Letter-by-letter time spent on words that have no chord.
    public var unchordedMs = 0.0
    public var chordsAdded = 0
    public var keystrokes = 0
    public var backspaces = 0
    /// Words-per-minute samples: characters (with the space) and the time
    /// from the end of the previous word, per input method.
    public var keyboardSpeedChars = 0
    public var keyboardSpeedMs = 0.0
    public var m4gLetterSpeedChars = 0
    public var m4gLetterSpeedMs = 0.0
    public var chordSpeedChars = 0
    public var chordSpeedMs = 0.0
    /// Chords deleted straight away, and chord-speed output that matched
    /// no chord and no word.
    public var deletedMisfires = 0
    public var garbledMisfires = 0

    public init(start: Date) {
        self.start = start
    }

    public var words: Int { chordedWords + m4gTypedWords + keyboardWords + awayWords + shorthandWords }
    public var handTypedWords: Int { m4gTypedWords + keyboardWords + awayWords }
    /// Words written while a chord was possible.
    public var chordableWords: Int { chordedWords + m4gTypedWords + keyboardWords }
    public var handTypingMs: Double { keyboardMs + m4gMs }

    public var chordRate: Double? { chordableWords > 0 ? Double(chordedWords) / Double(chordableWords) : nil }
    public var coverageRate: Double? { chordableWords > 0 ? Double(coveredWords) / Double(chordableWords) : nil }
    /// Typos per word typed by hand: chords never produce letter slips.
    public var typoRate: Double? { handTypedWords > 0 ? Double(typoWords) / Double(handTypedWords) : nil }
    public var misfires: Int { deletedMisfires + garbledMisfires }
    /// Misfires per chord attempt. Deleted chords never reached the stats,
    /// so they are added back to the attempts.
    public var misfireRate: Double? {
        let attempts = chordsUsed + deletedMisfires
        return attempts > 0 ? Double(misfires) / Double(attempts) : nil
    }
    /// Typos and misfires together, per word written.
    public var errorRate: Double? {
        let attempts = words + deletedMisfires
        return attempts > 0 ? Double(typoWords + misfires) / Double(attempts) : nil
    }

    /// Real typing speed: word plus space over the time since the previous
    /// word, pauses over three seconds left out.
    public var keyboardSpeedWPM: Double? { Self.wpm(letters: keyboardSpeedChars, ms: keyboardSpeedMs) }
    public var m4gLetterSpeedWPM: Double? { Self.wpm(letters: m4gLetterSpeedChars, ms: m4gLetterSpeedMs) }
    public var chordSpeedWPM: Double? { Self.wpm(letters: chordSpeedChars, ms: chordSpeedMs) }
    /// Everything written on the Master Forge, chords and letters together.
    public var m4gBlendedWPM: Double? {
        Self.wpm(letters: chordSpeedChars + m4gLetterSpeedChars, ms: chordSpeedMs + m4gLetterSpeedMs)
    }
    public var hasSpeedSamples: Bool { keyboardSpeedChars + m4gLetterSpeedChars + chordSpeedChars > 0 }
    public var keyboardWPM: Double? { Self.wpm(letters: keyboardLetters, ms: keyboardMs) }
    public var m4gWPM: Double? { Self.wpm(letters: m4gLetters, ms: m4gMs) }
    public var backspaceRate: Double? { keystrokes > 0 ? Double(backspaces) / Double(keystrokes) : nil }

    /// Standard words per minute: five characters per word. Needs a few
    /// words of evidence before it means anything.
    static func wpm(letters: Int, ms: Double) -> Double? {
        guard letters >= 25, ms > 0 else { return nil }
        return (Double(letters) / 5) / (ms / 60_000)
    }

    mutating func add(_ other: StatsBucket) {
        chordedWords += other.chordedWords
        m4gTypedWords += other.m4gTypedWords
        keyboardWords += other.keyboardWords
        awayWords += other.awayWords
        shorthandWords += other.shorthandWords
        chordsUsed += other.chordsUsed
        typoWords += other.typoWords
        coveredWords += other.coveredWords
        keyboardLetters += other.keyboardLetters
        keyboardMs += other.keyboardMs
        m4gLetters += other.m4gLetters
        m4gMs += other.m4gMs
        unchordedMs += other.unchordedMs
        chordsAdded += other.chordsAdded
        keystrokes += other.keystrokes
        backspaces += other.backspaces
        keyboardSpeedChars += other.keyboardSpeedChars
        keyboardSpeedMs += other.keyboardSpeedMs
        m4gLetterSpeedChars += other.m4gLetterSpeedChars
        m4gLetterSpeedMs += other.m4gLetterSpeedMs
        chordSpeedChars += other.chordSpeedChars
        chordSpeedMs += other.chordSpeedMs
        deletedMisfires += other.deletedMisfires
        garbledMisfires += other.garbledMisfires
    }
}

public struct StatsWordCount: Codable, Hashable, Sendable, Identifiable {
    public var id: String { word }
    public let word: String
    public let count: Int
    public let chordInput: [String]?

    public init(word: String, count: Int, chordInput: [String]? = nil) {
        self.word = word
        self.count = count
        self.chordInput = chordInput
    }
}

public struct StatsReport: Codable, Hashable, Sendable {
    public let period: StatsPeriod
    public let buckets: [StatsBucket]
    public let totals: StatsBucket
    /// The same measures for the period just before, for trend arrows.
    public let previousTotals: StatsBucket
    /// Days in the period with any recorded word.
    public let activeDays: Int
    /// Consecutive days up to today with at least one chord.
    public let chordStreakDays: Int
    public let bestDay: StatsBucket?
    public let topChorded: [StatsWordCount]
    public let topUnchorded: [StatsWordCount]
    /// Chords that misfired most, with their keys when known.
    public let topMisfires: [StatsWordCount]
    /// First day with words-per-minute samples.
    public let speedTrackingStart: Date?
    public let englishWords: Int
    public let arabicWords: Int
    public let otherWords: Int
    /// First day the recorder could tell chords from typing.
    public let attributionStart: Date?
    /// Totals from `attributionStart` on. Before it every word counted as
    /// typed, so chord measures are only honest over this range.
    public let trackedTotals: StatsBucket?

    /// Totals to use for chord measures: the tracked range when tracking
    /// began inside this period, otherwise the whole period.
    public var chordTotals: StatsBucket { trackedTotals ?? totals }

    /// Whether the previous period has enough data to compare against.
    public var hasComparablePrevious: Bool {
        previousTotals.words > 0 && Double(previousTotals.words) >= Double(totals.words) * 0.25
    }

    /// Whether chord measures in the previous period mean anything.
    public var hasComparablePreviousChords: Bool {
        hasComparablePrevious && trackedTotals == nil
    }

    public func isTracked(_ bucket: StatsBucket) -> Bool {
        guard let attributionStart else { return false }
        if period.bucketsByMonth {
            return Calendar.current.isDate(bucket.start, equalTo: attributionStart, toGranularity: .month)
                || bucket.start > attributionStart
        }
        return bucket.start >= attributionStart
    }

    public init(
        period: StatsPeriod,
        buckets: [StatsBucket],
        totals: StatsBucket,
        previousTotals: StatsBucket,
        activeDays: Int,
        chordStreakDays: Int,
        bestDay: StatsBucket?,
        topChorded: [StatsWordCount],
        topUnchorded: [StatsWordCount],
        englishWords: Int,
        arabicWords: Int,
        otherWords: Int,
        attributionStart: Date?,
        trackedTotals: StatsBucket? = nil,
        topMisfires: [StatsWordCount] = [],
        speedTrackingStart: Date? = nil
    ) {
        self.trackedTotals = trackedTotals
        self.topMisfires = topMisfires
        self.speedTrackingStart = speedTrackingStart
        self.period = period
        self.buckets = buckets
        self.totals = totals
        self.previousTotals = previousTotals
        self.activeDays = activeDays
        self.chordStreakDays = chordStreakDays
        self.bestDay = bestDay
        self.topChorded = topChorded
        self.topUnchorded = topUnchorded
        self.englishWords = englishWords
        self.arabicWords = arabicWords
        self.otherWords = otherWords
        self.attributionStart = attributionStart
    }

    public var averageWordsPerActiveDay: Double {
        activeDays > 0 ? Double(totals.words) / Double(activeDays) : 0
    }

    public static func empty(_ period: StatsPeriod) -> StatsReport {
        StatsReport(
            period: period,
            buckets: [],
            totals: StatsBucket(start: .distantPast),
            previousTotals: StatsBucket(start: .distantPast),
            activeDays: 0,
            chordStreakDays: 0,
            bestDay: nil,
            topChorded: [],
            topUnchorded: [],
            englishWords: 0,
            arabicWords: 0,
            otherWords: 0,
            attributionStart: nil
        )
    }
}

/// One aggregated row of `daily_word_stats`.
public struct DailyWordRow: Hashable, Sendable {
    public let day: String
    public let word: String
    public let source: UsageSource
    public let language: WordLanguage
    public let frequency: Int
    public let avgMs: Double

    public init(day: String, word: String, source: UsageSource, language: WordLanguage, frequency: Int, avgMs: Double) {
        self.day = day
        self.word = word
        self.source = source
        self.language = language
        self.frequency = frequency
        self.avgMs = avgMs
    }
}

/// Pure aggregation of recorded rows into a report.
public struct StatsBuilder: Sendable {
    public let period: StatsPeriod
    public let now: Date
    public let calendar: Calendar

    public init(period: StatsPeriod, now: Date = .now, calendar: Calendar = .current) {
        self.period = period
        self.now = now
        self.calendar = calendar
    }

    /// First day of the current period and of the one before it.
    public var currentStart: Date {
        if period.bucketsByMonth {
            let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
            return calendar.date(byAdding: .month, value: -11, to: thisMonth) ?? thisMonth
        }
        return calendar.date(byAdding: .day, value: -(period.days - 1), to: calendar.startOfDay(for: now)) ?? now
    }

    public var previousStart: Date {
        if period.bucketsByMonth {
            return calendar.date(byAdding: .month, value: -12, to: currentStart) ?? currentStart
        }
        return calendar.date(byAdding: .day, value: -period.days, to: currentStart) ?? currentStart
    }

    public func build(
        wordRows: [DailyWordRow],
        chordRows: [(day: String, frequency: Int)],
        addedChordDays: [String],
        keyRows: [(day: String, keystrokes: Int, backspaces: Int)],
        chordedWords: [String: [String]],
        typoWords: Set<String>,
        mergedWords: [String: String],
        attributionStartDay: String? = nil,
        speedRows: [(day: String, method: SpeedMethod, characters: Int, ms: Double)] = [],
        misfireRows: [(day: String, word: String, kind: MisfireKind, frequency: Int)] = []
    ) -> StatsReport {
        var current: [Date: StatsBucket] = [:]
        var previous = StatsBucket(start: previousStart)
        var dailyWords: [Date: Int] = [:]
        var dailyChorded: [Date: Int] = [:]
        var chordedCounts: [String: Int] = [:]
        var unchordedCounts: [String: Int] = [:]
        var english = 0
        var arabic = 0
        var other = 0
        var attributionStart: Date? = attributionStartDay.flatMap { date(for: $0) }
        let knowsAttributionStart = attributionStart != nil

        func withBucket(day: String, _ update: (inout StatsBucket) -> Void) {
            guard let date = date(for: day), date >= previousStart else { return }
            if date >= currentStart {
                let start = bucketStart(for: date)
                var bucket = current[start] ?? StatsBucket(start: start)
                update(&bucket)
                current[start] = bucket
            } else {
                update(&previous)
            }
        }

        for row in wordRows where row.source != .nexusImport {
            let word = mergedWords[row.word] ?? row.word
            let hasChord = chordedWords[word] != nil
            let isTypo = typoWords.contains(row.word)
            let letters = row.word.count * row.frequency
            let time = min(row.avgMs, 3_000) * Double(row.frequency)
            withBucket(day: row.day) { bucket in
                switch row.source {
                case .m4gHIDConfirmed, .softwareChord:
                    bucket.chordedWords += row.frequency
                case .m4gTyping:
                    bucket.m4gTypedWords += row.frequency
                    bucket.m4gLetters += letters
                    bucket.m4gMs += time
                case .keyboard:
                    bucket.keyboardWords += row.frequency
                    bucket.keyboardLetters += letters
                    bucket.keyboardMs += time
                case .keyboardAway:
                    bucket.awayWords += row.frequency
                    bucket.keyboardLetters += letters
                    bucket.keyboardMs += time
                case .laptopShorthand:
                    bucket.shorthandWords += row.frequency
                case .nexusImport:
                    break
                }
                if hasChord, row.source != .keyboardAway, row.source != .laptopShorthand {
                    bucket.coveredWords += row.frequency
                }
                if isTypo { bucket.typoWords += row.frequency }
                if !hasChord, row.source == .keyboard || row.source == .m4gTyping {
                    bucket.unchordedMs += time
                }
            }

            guard let date = date(for: row.day), date >= currentStart else { continue }
            let day = calendar.startOfDay(for: date)
            dailyWords[day, default: 0] += row.frequency
            if !knowsAttributionStart, row.source == .m4gHIDConfirmed || row.source == .m4gTyping {
                attributionStart = min(attributionStart ?? day, day)
            }
            if row.source == .m4gHIDConfirmed || row.source == .softwareChord {
                dailyChorded[day, default: 0] += row.frequency
                chordedCounts[word, default: 0] += row.frequency
            } else if !hasChord, !isTypo, row.language == .english, word.count >= 3 {
                unchordedCounts[word, default: 0] += row.frequency
            }
            switch row.language {
            case .english: english += row.frequency
            case .arabic: arabic += row.frequency
            case .mixed, .other: other += row.frequency
            }
        }

        for row in chordRows {
            withBucket(day: row.day) { $0.chordsUsed += row.frequency }
        }
        for day in addedChordDays {
            withBucket(day: day) { $0.chordsAdded += 1 }
        }
        var speedStart: Date?
        for row in speedRows {
            if let date = date(for: row.day) {
                speedStart = min(speedStart ?? date, date)
            }
            withBucket(day: row.day) { bucket in
                switch row.method {
                case .keyboard:
                    bucket.keyboardSpeedChars += row.characters
                    bucket.keyboardSpeedMs += row.ms
                case .m4gLetters:
                    bucket.m4gLetterSpeedChars += row.characters
                    bucket.m4gLetterSpeedMs += row.ms
                case .m4gChords:
                    bucket.chordSpeedChars += row.characters
                    bucket.chordSpeedMs += row.ms
                }
            }
        }
        var misfireCounts: [String: Int] = [:]
        for row in misfireRows {
            withBucket(day: row.day) { bucket in
                switch row.kind {
                case .deleted: bucket.deletedMisfires += row.frequency
                case .garbled: bucket.garbledMisfires += row.frequency
                }
            }
            if let date = date(for: row.day), date >= currentStart {
                misfireCounts[row.word, default: 0] += row.frequency
            }
        }
        for row in keyRows {
            withBucket(day: row.day) { bucket in
                bucket.keystrokes += row.keystrokes
                bucket.backspaces += row.backspaces
            }
        }

        let buckets = allBucketStarts().map { current[$0] ?? StatsBucket(start: $0) }
        var totals = StatsBucket(start: currentStart)
        for bucket in buckets { totals.add(bucket) }

        var streak = 0
        var cursor = calendar.startOfDay(for: now)
        if (dailyChorded[cursor] ?? 0) == 0 {
            // Today may not have started yet; count the streak up to yesterday.
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while (dailyChorded[cursor] ?? 0) > 0 {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }

        // Chord measures only count from the first day the recorder could
        // attribute keys to the M4G, when that day falls inside the period.
        var trackedTotals: StatsBucket?
        if let attributionStart, attributionStart > currentStart {
            let trackedStart = bucketStart(for: attributionStart)
            var tracked = StatsBucket(start: trackedStart)
            for bucket in buckets where bucket.start >= trackedStart {
                tracked.add(bucket)
            }
            trackedTotals = tracked
        }

        let bestDay = dailyWords.max { $0.value < $1.value }.flatMap { day, _ -> StatsBucket? in
            period.bucketsByMonth ? nil : current[day]
        }

        return StatsReport(
            period: period,
            buckets: buckets,
            totals: totals,
            previousTotals: previous,
            activeDays: dailyWords.values.filter { $0 > 0 }.count,
            chordStreakDays: streak,
            bestDay: bestDay,
            topChorded: Self.top(chordedCounts, chords: chordedWords),
            topUnchorded: Self.top(unchordedCounts, chords: [:]),
            englishWords: english,
            arabicWords: arabic,
            otherWords: other,
            attributionStart: attributionStart,
            trackedTotals: trackedTotals,
            topMisfires: Self.top(misfireCounts, chords: chordedWords, limit: 8),
            speedTrackingStart: speedStart
        )
    }

    private static func top(_ counts: [String: Int], chords: [String: [String]], limit: Int = 10) -> [StatsWordCount] {
        counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { StatsWordCount(word: $0.key, count: $0.value, chordInput: chords[$0.key]) }
    }

    private func allBucketStarts() -> [Date] {
        var starts: [Date] = []
        var cursor = currentStart
        let component: Calendar.Component = period.bucketsByMonth ? .month : .day
        while cursor <= now {
            starts.append(cursor)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        return starts
    }

    private func bucketStart(for date: Date) -> Date {
        if period.bucketsByMonth {
            return calendar.dateInterval(of: .month, for: date)?.start ?? date
        }
        return calendar.startOfDay(for: date)
    }

    private func date(for day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
