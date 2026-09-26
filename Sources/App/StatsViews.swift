import AppKit
import Charts
import Library
import SwiftUI

// MARK: - Palette

/// One color per entity, the same in every chart: a series keeps its color
/// wherever it appears. Validated for colorblind separation on the macOS
/// light and dark window surfaces; light-mode orange and aqua sit below 3:1
/// contrast, so every chart also carries a text legend and a value readout.
enum StatsPalette {
    static let chorded = dynamic(light: 0x2A78D6, dark: 0x3987E5)
    static let m4gTyped = dynamic(light: 0xEB6834, dark: 0xD95926)
    static let keyboard = dynamic(light: 0x1BAF7A, dark: 0x199E70)
    static let typos = dynamic(light: 0xE87BA4, dark: 0xD55181)
    static let time = dynamic(light: 0xEDA100, dark: 0xC98500)
    static let library = dynamic(light: 0x4A3AA7, dark: 0x9085E9)
    static let misfires = dynamic(light: 0xE34948, dark: 0xE66767)
    /// Everything on the Master Forge together: a neutral, emphasized line.
    static let blended = Color.primary.opacity(0.75)
    static let context = Color.secondary.opacity(0.45)
    static let grid = Color.secondary.opacity(0.18)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

// MARK: - Stats tab

struct StatsTabView<Details: View>: View {
    @ObservedObject var model: AppModel
    @ViewBuilder let details: () -> Details

    private var report: StatsReport { model.statsReport }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controls
                if model.isLoadingStats && report.buckets.isEmpty {
                    ProgressView("Crunching your typing history…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    headline
                    kpiGrid
                    WordsChartCard(report: report)
                    ChordRateChartCard(report: report)
                    if report.totals.hasSpeedSamples {
                        SpeedSection(report: report)
                    } else {
                        SpeedChartCard(report: report)
                    }
                    AccuracySection(model: model, report: report)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16, alignment: .top)], spacing: 16) {
                        ChordsUsedChartCard(report: report)
                        TypingTimeChartCard(report: report)
                        ChordsAddedChartCard(report: report)
                    }
                    wordLists
                    languageCard
                    DisclosureGroup("Coverage details and raw activity") {
                        details()
                            .padding(.top, 8)
                    }
                    .font(.callout)
                }
            }
            .padding(.vertical, 4)
        }
        .task(id: model.statsPeriod) {
            await model.loadStats()
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Label(
                    model.inputObserver.isRunning ? "Recording" : "Recorder paused",
                    systemImage: model.inputObserver.isRunning ? "record.circle" : "pause.circle"
                )
                .foregroundStyle(model.inputObserver.isRunning ? .green : .secondary)
                .font(.caption.weight(.semibold))
                Text(model.inputObserver.attributionStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.inputObserver.needsInputMonitoringPermission {
                    Button("Input Monitoring…") { model.openInputMonitoringSettings() }
                        .controlSize(.small)
                }
                Button(model.inputObserver.isRunning ? "Pause" : "Resume") {
                    model.toggleInputObservation()
                }
                .controlSize(.small)
            }
            HStack {
                Picker("Period", selection: $model.statsPeriod) {
                    ForEach(StatsPeriod.allCases) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                if model.isLoadingStats {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if model.inputObserver.isRunning {
                    Text("This session: \(model.inputObserver.m4gAttributedKeyCount.formatted()) M4G keys · \(model.inputObserver.otherKeyboardKeyCount.formatted()) other")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Headline

    private var headline: some View {
        let totals = report.totals
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(totals.words.formatted()) words in the \(report.period.displayName)")
                .font(.title2.weight(.semibold))
            Text(headlineDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var headlineDetail: String {
        let totals = report.totals
        guard totals.words > 0 else { return "Nothing recorded in this period yet." }
        var parts: [String] = []
        let chordTotals = report.chordTotals
        if report.attributionStart == nil {
            parts.append("chords are counted once the recorder sees your Master Forge")
        } else if report.trackedTotals != nil, let start = report.attributionStart {
            parts.append("since chord tracking began on \(start.formatted(.dateTime.month(.wide).day())), \(Self.percent(chordTotals.chordRate)) came from chords")
        } else {
            parts.append("\(Self.percent(chordTotals.chordRate)) came from chords")
        }
        if let coverage = totals.coverageRate {
            parts.append("you had a chord for \(Self.percent(coverage)) of all words")
        }
        if let blended = totals.m4gBlendedWPM {
            parts.append("you write \(Int(blended.rounded())) WPM on the M4G with chords and letters together")
        }
        if let m4g = totals.m4gLetterSpeedWPM ?? totals.m4gWPM, let keyboard = totals.keyboardSpeedWPM ?? totals.keyboardWPM {
            parts.append("letter by letter \(Int(m4g.rounded())) WPM on the M4G and \(Int(keyboard.rounded())) WPM on other keyboards")
        }
        if totals.awayWords > 0 {
            parts.append("\(totals.awayWords.formatted()) words typed with no M4G connected don't count against your chord rate")
        }
        let sentence = parts.joined(separator: "; ") + "."
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    // MARK: KPIs

    private var kpiGrid: some View {
        let totals = report.totals
        let previous = report.previousTotals
        let chords = report.chordTotals
        let comparable = report.hasComparablePrevious
        let comparableChords = report.hasComparablePreviousChords
        let days = Double(max(report.period.days, 1))
        let trackedFootnote = report.trackedTotals != nil
            ? "since \(report.attributionStart?.formatted(.dateTime.month(.abbreviated).day()) ?? "")"
            : "\(chords.chordedWords.formatted()) words"
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            StatTile(
                title: "Words per day",
                value: Int((Double(totals.words) / days).rounded()).formatted(),
                delta: comparable ? .relative(current: Double(totals.words), previous: Double(previous.words), higherIsBetter: true) : nil,
                footnote: "\(totals.words.formatted()) in total"
            )
            StatTile(
                title: "Chorded",
                value: Self.percent(chords.chordRate),
                delta: comparableChords ? .points(current: chords.chordRate, previous: previous.chordRate, higherIsBetter: true) : nil,
                footnote: trackedFootnote,
                swatch: StatsPalette.chorded
            )
            StatTile(
                title: "Had a chord",
                value: Self.percent(totals.coverageRate),
                delta: comparable ? .points(current: totals.coverageRate, previous: previous.coverageRate, higherIsBetter: true) : nil,
                footnote: "library coverage"
            )
            StatTile(
                title: "M4G speed, blended",
                value: totals.m4gBlendedWPM.map { "\(Int($0.rounded())) WPM" } ?? "—",
                delta: comparable && totals.m4gBlendedWPM != nil && previous.m4gBlendedWPM != nil
                    ? .relative(current: totals.m4gBlendedWPM, previous: previous.m4gBlendedWPM, higherIsBetter: true)
                    : nil,
                footnote: m4gSpeedFootnote,
                swatch: StatsPalette.blended
            )
            StatTile(
                title: "Errors",
                value: totals.errorRate.map { String(format: "%.1f", $0 * 100) } ?? "—",
                delta: comparable ? .points(current: totals.errorRate, previous: previous.errorRate, higherIsBetter: false) : nil,
                footnote: "typos + misfires / 100 words",
                swatch: StatsPalette.typos
            )
            StatTile(
                title: "Typing by hand",
                value: Self.duration(totals.handTypingMs),
                delta: comparable ? .relative(current: totals.handTypingMs, previous: previous.handTypingMs, higherIsBetter: false) : nil,
                footnote: "\(Self.duration(totals.unchordedMs)) with no chord",
                swatch: StatsPalette.time
            )
            StatTile(
                title: "Chord streak",
                value: "\(report.chordStreakDays) day\(report.chordStreakDays == 1 ? "" : "s")",
                delta: nil,
                footnote: "\(totals.chordsAdded) chords added"
            )
        }
    }

    /// Chords and letters behind the blend, or what is still being measured.
    private var m4gSpeedFootnote: String {
        let totals = report.totals
        if totals.m4gBlendedWPM != nil {
            let parts = [
                totals.chordSpeedWPM.map { "chords \(Int($0.rounded()))" },
                totals.m4gLetterSpeedWPM.map { "letters \(Int($0.rounded()))" }
            ].compactMap { $0 }
            return parts.joined(separator: " · ") + " WPM"
        }
        if let letters = totals.m4gWPM {
            return "measuring · letters \(Int(letters.rounded())) WPM"
        }
        return "measuring: type on the M4G"
    }

    // MARK: Lists

    private var wordLists: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16, alignment: .top)], spacing: 16) {
            StatsCard(title: "Most chorded", summary: report.topChorded.isEmpty ? "No chorded words recorded in this period." : "Your most-used chords in the \(report.period.displayName).") {
                RankedWordList(items: report.topChorded, tint: StatsPalette.chorded)
            }
            StatsCard(title: "Most typed without a chord", summary: "The biggest candidates for new chords.") {
                VStack(alignment: .leading, spacing: 8) {
                    RankedWordList(items: report.topUnchorded, tint: StatsPalette.context)
                    Button("Plan chords in Grow") { model.selectedTab = .grow }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    private var languageCard: some View {
        let total = max(report.englishWords + report.arabicWords + report.otherWords, 1)
        let english = Double(report.englishWords) / Double(total)
        let arabic = Double(report.arabicWords) / Double(total)
        return StatsCard(
            title: "Languages",
            summary: "\(Self.percent(english)) English, \(Self.percent(arabic)) Arabic. Arabic chords need a matching macOS input source."
        ) {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        Rectangle().fill(Color.primary.opacity(0.55)).frame(width: max(0, proxy.size.width * english - 1))
                        Rectangle().fill(StatsPalette.context)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                HStack(spacing: 14) {
                    LegendItem(color: Color.primary.opacity(0.55), label: "English", value: report.englishWords.formatted())
                    LegendItem(color: StatsPalette.context, label: "Arabic", value: report.arabicWords.formatted())
                }
            }
        }
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        let percent = value * 100
        return percent > 0 && percent < 1 ? String(format: "%.1f%%", percent) : "\(Int(percent.rounded()))%"
    }

    static func duration(_ ms: Double) -> String {
        let minutes = Int((ms / 60_000).rounded())
        if minutes >= 60 {
            return "\(minutes / 60) h \(minutes % 60) min"
        }
        return "\(minutes) min"
    }
}

// MARK: - Cards and tiles

struct StatsCard<Content: View>: View {
    let title: String
    let summary: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

enum StatDelta {
    case relative(current: Double?, previous: Double?, higherIsBetter: Bool)
    case points(current: Double?, previous: Double?, higherIsBetter: Bool)

    var text: String? {
        switch self {
        case .relative(let current, let previous, _):
            guard let current, let previous, previous > 0 else { return nil }
            let change = (current - previous) / previous * 100
            guard abs(change) >= 1 else { return "about the same" }
            return String(format: "%@%.0f%% vs previous", change > 0 ? "+" : "−", abs(change))
        case .points(let current, let previous, _):
            guard let current, let previous else { return nil }
            let change = (current - previous) * 100
            guard abs(change) >= 0.1 else { return "about the same" }
            return String(format: "%@%.1f pts vs previous", change > 0 ? "+" : "−", abs(change))
        }
    }

    /// nil when unchanged or unknown.
    var isImprovement: Bool? {
        let pair: (Double?, Double?, Bool)
        switch self {
        case .relative(let current, let previous, let higherIsBetter),
             .points(let current, let previous, let higherIsBetter):
            pair = (current, previous, higherIsBetter)
        }
        guard let current = pair.0, let previous = pair.1, current != previous else { return nil }
        return (current > previous) == pair.2
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let delta: StatDelta?
    let footnote: String
    var swatch: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let swatch {
                    Circle().fill(swatch).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let delta, let text = delta.text {
                HStack(spacing: 3) {
                    if let improved = delta.isImprovement {
                        Image(systemName: improved ? "arrow.up.right" : "arrow.down.right")
                    }
                    Text(text)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(deltaColor(delta))
            } else {
                // Keep every tile the same height.
                Text(" ").font(.caption2).accessibilityHidden(true)
            }
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func deltaColor(_ delta: StatDelta) -> Color {
        switch delta.isImprovement {
        case .some(true): return .green
        case .some(false): return .orange
        case .none: return .secondary
        }
    }
}

private struct RankedWordList: View {
    let items: [StatsWordCount]
    let tint: Color

    var body: some View {
        let maximum = Double(items.map(\.count).max() ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Text(item.word)
                        .font(.callout)
                        .frame(width: 110, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(tint)
                            .frame(width: max(2, proxy.size.width * Double(item.count) / maximum))
                    }
                    .frame(height: 6)
                    Text(item.count.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.word)
                .accessibilityValue("\(item.count) times")
            }
        }
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    let value: String?

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Chart plumbing

private enum ChartAxes {
    static func dateFormat(for period: StatsPeriod) -> Date.FormatStyle {
        switch period {
        case .week: return .dateTime.weekday(.abbreviated)
        case .month, .quarter: return .dateTime.month(.abbreviated).day()
        case .year: return .dateTime.month(.abbreviated)
        }
    }

    static func unit(for period: StatsPeriod) -> Calendar.Component {
        period.bucketsByMonth ? .month : .day
    }

    static func strideCount(for period: StatsPeriod) -> Int {
        switch period {
        case .week: return 1
        case .month: return 7
        case .quarter: return 21
        case .year: return 2
        }
    }

    /// Evenly spaced label dates that never land at the trailing edge, where
    /// the last label would be clipped by the plot bounds.
    static func labelDates(_ report: StatsReport) -> [Date] {
        let stride = strideCount(for: report.period)
        let starts = report.buckets.map(\.start)
        let lastAllowed = starts.count - 1 - (stride > 1 ? max(1, stride / 2) : 0)
        return starts.enumerated()
            .filter { $0.offset % stride == 0 && $0.offset <= lastAllowed }
            .map(\.element)
    }

    static func readoutDate(_ date: Date, period: StatsPeriod) -> String {
        period.bucketsByMonth
            ? date.formatted(.dateTime.month(.wide).year())
            : date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// Scrubbing over the whole plot area selects the nearest bucket, the way
/// Health and Stocks reveal a value without requiring precise pointing.
private struct BucketHoverOverlay: View {
    let proxy: ChartProxy
    let buckets: [StatsBucket]
    @Binding var selected: StatsBucket?

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let origin = geometry[proxy.plotAreaFrame].origin
                        guard let date: Date = proxy.value(atX: location.x - origin.x) else { return }
                        selected = buckets.min { lhs, rhs in
                            abs(lhs.start.timeIntervalSince(date)) < abs(rhs.start.timeIntervalSince(date))
                        }
                    case .ended:
                        selected = nil
                    }
                }
        }
    }
}

private extension View {
    func statsAxes(report: StatsReport, percent: Bool = false) -> some View {
        chartXAxis {
            AxisMarks(values: ChartAxes.labelDates(report)) { _ in
                AxisTick().foregroundStyle(StatsPalette.grid)
                AxisValueLabel(format: ChartAxes.dateFormat(for: report.period))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(StatsPalette.grid)
                AxisValueLabel {
                    if percent, let number = value.as(Double.self) {
                        Text("\(Int((number * 100).rounded()))%")
                    } else if let number = value.as(Double.self) {
                        Text(number.formatted(.number.notation(.compactName)))
                    }
                }
            }
        }
    }
}

/// Describes a chart to VoiceOver and Audio Graphs.
private struct StatsChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let summary: String
    let valueName: String
    let series: [(name: String, points: [(Date, Double)])]
    let period: StatsPeriod

    func makeChartDescriptor() -> AXChartDescriptor {
        let dates = series.flatMap { $0.points.map(\.0) }
        let values = series.flatMap { $0.points.map(\.1) }
        let minDate = dates.min() ?? .now
        let maxDate = dates.max() ?? .now
        let xAxis = AXNumericDataAxisDescriptor(
            title: period.bucketsByMonth ? "Month" : "Day",
            range: minDate.timeIntervalSince1970...max(maxDate.timeIntervalSince1970, minDate.timeIntervalSince1970 + 1),
            gridlinePositions: []
        ) { value in
            ChartAxes.readoutDate(Date(timeIntervalSince1970: value), period: period)
        }
        let yAxis = AXNumericDataAxisDescriptor(
            title: valueName,
            range: 0...max(values.max() ?? 1, 1),
            gridlinePositions: []
        ) { value in "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(valueName)" }
        return AXChartDescriptor(
            title: title,
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: series.map { item in
                AXDataSeriesDescriptor(
                    name: item.name,
                    isContinuous: false,
                    dataPoints: item.points.map { AXDataPoint(x: $0.0.timeIntervalSince1970, y: $0.1) }
                )
            }
        )
    }
}

// MARK: - Words per day

private struct WordsChartCard: View {
    let report: StatsReport
    @State private var selected: StatsBucket?
    @State private var showsTable = false

    private struct Segment: Identifiable {
        let id: String
        let bucket: StatsBucket
        let series: String
        let color: Color
        let start: Double
        let end: Double
        let count: Int
    }

    private var segments: [Segment] {
        let maxTotal = Double(report.buckets.map(\.words).max() ?? 0)
        // A thin gap between stacked segments, per the HIG's advice to
        // separate contiguous areas of color.
        let gap = maxTotal * 0.012
        return report.buckets.flatMap { bucket -> [Segment] in
            var cumulative = 0.0
            let parts: [(String, Color, Int)] = [
                ("Chorded", StatsPalette.chorded, bucket.chordedWords),
                ("Typed on M4G", StatsPalette.m4gTyped, bucket.m4gTypedWords),
                ("Other keyboard", StatsPalette.keyboard, bucket.keyboardWords),
                ("M4G not connected", StatsPalette.context, bucket.awayWords)
            ]
            return parts.compactMap { name, color, count in
                guard count > 0 else { return nil }
                let start = cumulative
                cumulative += Double(count)
                let inset = Double(count) > gap * 3 ? gap / 2 : 0
                return Segment(
                    id: "\(bucket.start.timeIntervalSince1970)-\(name)",
                    bucket: bucket,
                    series: name,
                    color: color,
                    start: start + (start > 0 ? inset : 0),
                    end: cumulative,
                    count: count
                )
            }
        }
    }

    private var average: Double {
        let active = report.buckets.filter { $0.words > 0 }
        guard !active.isEmpty else { return 0 }
        return Double(active.map(\.words).reduce(0, +)) / Double(active.count)
    }

    var body: some View {
        StatsCard(title: report.period.bucketsByMonth ? "Words per month" : "Words per day", summary: summary) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    LegendItem(color: StatsPalette.chorded, label: "Chorded", value: report.totals.chordedWords.formatted())
                    LegendItem(color: StatsPalette.m4gTyped, label: "Typed on M4G", value: report.totals.m4gTypedWords.formatted())
                    LegendItem(color: StatsPalette.keyboard, label: "Other keyboard", value: report.totals.keyboardWords.formatted())
                    if report.totals.awayWords > 0 {
                        LegendItem(color: StatsPalette.context, label: "M4G not connected", value: report.totals.awayWords.formatted())
                            .help("Typed while no Master Forge was plugged in. These count as typing but not against your chord rate.")
                    }
                    Spacer()
                    Toggle("Table", isOn: $showsTable)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Show the numbers as a table")
                }
                if showsTable {
                    table
                } else {
                    chart
                }
            }
        }
    }

    private var summary: String {
        if let selected {
            return "\(ChartAxes.readoutDate(selected.start, period: report.period)): \(selected.words.formatted()) words · \(selected.chordedWords.formatted()) chorded · \(selected.m4gTypedWords.formatted()) typed on M4G · \(selected.keyboardWords.formatted()) other keyboard"
        }
        var text = "Average \(Int(average.rounded()).formatted()) words per active \(report.period.bucketsByMonth ? "month" : "day")"
        if let best = report.bestDay {
            text += "; busiest was \(best.start.formatted(.dateTime.month(.abbreviated).day())) with \(best.words.formatted())"
        }
        text += "."
        if report.trackedTotals != nil, let start = report.attributionStart {
            text += " Before \(start.formatted(.dateTime.month(.abbreviated).day())) chorded and M4G words were counted as other keyboard."
        }
        return text
    }

    private var chart: some View {
        Chart {
            ForEach(segments) { segment in
                BarMark(
                    x: .value("Date", segment.bucket.start, unit: ChartAxes.unit(for: report.period)),
                    yStart: .value("Words", segment.start),
                    yEnd: .value("Words", segment.end),
                    width: .ratio(0.7)
                )
                .foregroundStyle(segment.color)
                .cornerRadius(2)
                .opacity(selected == nil || selected?.start == segment.bucket.start ? 1 : 0.45)
                .accessibilityLabel("\(ChartAxes.readoutDate(segment.bucket.start, period: report.period)), \(segment.series)")
                .accessibilityValue("\(segment.count) words")
            }
            if average > 0 {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .leading) {
                        Text("avg \(Int(average.rounded()).formatted())")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.start, unit: ChartAxes.unit(for: report.period)))
                    .foregroundStyle(Color.secondary.opacity(0.15))
                    .lineStyle(StrokeStyle(lineWidth: 12))
                    .accessibilityHidden(true)
            }
        }
        .chartOverlay { proxy in
            BucketHoverOverlay(proxy: proxy, buckets: report.buckets, selected: $selected)
        }
        .statsAxes(report: report)
        .frame(height: 190)
        .accessibilityChartDescriptor(
            StatsChartDescriptor(
                title: "Words per day",
                summary: summary,
                valueName: "words",
                series: [
                    ("Chorded", report.buckets.map { ($0.start, Double($0.chordedWords)) }),
                    ("Typed on M4G", report.buckets.map { ($0.start, Double($0.m4gTypedWords)) }),
                    ("Other keyboard", report.buckets.map { ($0.start, Double($0.keyboardWords)) }),
                    ("M4G not connected", report.buckets.map { ($0.start, Double($0.awayWords)) })
                ],
                period: report.period
            )
        )
    }

    private var table: some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("Date").gridColumnAlignment(.leading)
                Text("Chorded")
                Text("M4G")
                Text("Other")
                Text("No M4G")
                Text("Total")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(report.buckets.reversed().filter { $0.words > 0 }) { bucket in
                GridRow {
                    Text(bucket.start.formatted(ChartAxes.dateFormat(for: report.period)))
                    Text(bucket.chordedWords.formatted())
                    Text(bucket.m4gTypedWords.formatted())
                    Text(bucket.keyboardWords.formatted())
                    Text(bucket.awayWords.formatted())
                    Text(bucket.words.formatted()).fontWeight(.semibold)
                }
                .font(.caption.monospacedDigit())
            }
        }
    }
}

// MARK: - Chord rate vs coverage

private struct ChordRateChartCard: View {
    let report: StatsReport
    @State private var selected: StatsBucket?

    private var summary: String {
        if let selected {
            return "\(ChartAxes.readoutDate(selected.start, period: report.period)): \(StatsTabView<EmptyView>.percent(selected.chordRate)) chorded, chord available for \(StatsTabView<EmptyView>.percent(selected.coverageRate))."
        }
        guard report.attributionStart != nil else {
            return "Chord use appears here once the recorder sees your Master Forge. Library coverage is shown meanwhile."
        }
        let chorded = report.chordTotals.chordRate ?? 0
        let coverage = report.chordTotals.coverageRate ?? 0
        let gap = max(0, coverage - chorded) * 100
        let since = report.trackedTotals != nil
            ? "Since \(report.attributionStart?.formatted(.dateTime.month(.abbreviated).day()) ?? "tracking began") you"
            : "You"
        return "\(since) chorded \(StatsTabView<EmptyView>.percent(chorded)) of words and had a chord for \(StatsTabView<EmptyView>.percent(coverage)). The \(Int(gap.rounded()))-point gap is chords you have but did not use."
    }

    var body: some View {
        StatsCard(title: "Chord rate", summary: summary) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    LegendItem(color: StatsPalette.chorded, label: "Chorded", value: nil)
                    LegendItem(color: StatsPalette.context, label: "Had a chord", value: nil)
                    if let start = report.attributionStart {
                        Spacer()
                        Text("Chord tracking since \(start.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Chart {
                    ForEach(report.buckets.filter { $0.words > 0 }) { bucket in
                        if let coverage = bucket.coverageRate {
                            LineMark(
                                x: .value("Date", bucket.start, unit: ChartAxes.unit(for: report.period)),
                                y: .value("Rate", coverage),
                                series: .value("Series", "Had a chord")
                            )
                            .foregroundStyle(StatsPalette.context)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .accessibilityLabel("\(ChartAxes.readoutDate(bucket.start, period: report.period)), had a chord")
                            .accessibilityValue(StatsTabView<EmptyView>.percent(coverage))
                        }
                        if report.isTracked(bucket), let rate = bucket.chordRate {
                            LineMark(
                                x: .value("Date", bucket.start, unit: ChartAxes.unit(for: report.period)),
                                y: .value("Rate", rate),
                                series: .value("Series", "Chorded")
                            )
                            .foregroundStyle(StatsPalette.chorded)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(
                                x: .value("Date", bucket.start, unit: ChartAxes.unit(for: report.period)),
                                y: .value("Rate", rate)
                            )
                            .foregroundStyle(StatsPalette.chorded)
                            .symbolSize(selected?.start == bucket.start ? 60 : 18)
                            .accessibilityLabel("\(ChartAxes.readoutDate(bucket.start, period: report.period)), chorded")
                            .accessibilityValue(StatsTabView<EmptyView>.percent(rate))
                        }
                    }
                    if let start = report.attributionStart, !report.period.bucketsByMonth {
                        RuleMark(x: .value("Tracking starts", start, unit: .day))
                            .foregroundStyle(Color.secondary.opacity(0.35))
                            .accessibilityHidden(true)
                    }
                    if let selected {
                        RuleMark(x: .value("Selected", selected.start, unit: ChartAxes.unit(for: report.period)))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                            .accessibilityHidden(true)
                    }
                }
                // Rates are fixed to 0–100% so days compare honestly.
                .chartYScale(domain: 0...1)
                .chartOverlay { proxy in
                    BucketHoverOverlay(proxy: proxy, buckets: report.buckets, selected: $selected)
                }
                .statsAxes(report: report, percent: true)
                .frame(height: 160)
            }
        }
    }
}

// MARK: - Letter-by-letter speed

private struct SpeedChartCard: View {
    let report: StatsReport
    @State private var selected: StatsBucket?

    private var summary: String {
        if let selected {
            let m4g = selected.m4gWPM.map { "\(Int($0.rounded())) WPM on M4G" } ?? "no M4G typing"
            let keyboard = selected.keyboardWPM.map { "\(Int($0.rounded())) WPM on other keyboards" } ?? "no other keyboard typing"
            return "\(ChartAxes.readoutDate(selected.start, period: report.period)): \(m4g), \(keyboard)."
        }
        switch (report.totals.m4gWPM, report.totals.keyboardWPM) {
        case (let m4g?, let keyboard?):
            let gap = Int((keyboard - m4g).rounded())
            return gap > 0
                ? "Letter by letter you type \(Int(m4g.rounded())) WPM on the M4G and \(Int(keyboard.rounded())) WPM elsewhere. Closing that \(gap) WPM gap is what stops unchorded words from sending you back to the laptop."
                : "Letter by letter you type \(Int(m4g.rounded())) WPM on the M4G, as fast as on other keyboards."
        case (nil, let keyboard?):
            return "\(Int(keyboard.rounded())) WPM letter by letter on other keyboards. M4G typing speed appears once the M4G has typed a few words."
        default:
            return "Not enough letter-by-letter typing recorded yet."
        }
    }

    var body: some View {
        StatsCard(title: "Letter-by-letter speed", summary: summary) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    LegendItem(color: StatsPalette.m4gTyped, label: "M4G", value: report.totals.m4gWPM.map { "\(Int($0.rounded())) WPM" })
                    LegendItem(color: StatsPalette.keyboard, label: "Other keyboard", value: report.totals.keyboardWPM.map { "\(Int($0.rounded())) WPM" })
                }
                Chart {
                    ForEach(report.buckets) { bucket in
                        if let wpm = bucket.keyboardWPM {
                            LineMark(
                                x: .value("Date", bucket.start, unit: ChartAxes.unit(for: report.period)),
                                y: .value("WPM", wpm),
                                series: .value("Keyboard", "Other keyboard")
                            )
                            .foregroundStyle(StatsPalette.keyboard)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .accessibilityLabel("\(ChartAxes.readoutDate(bucket.start, period: report.period)), other keyboard")
                            .accessibilityValue("\(Int(wpm.rounded())) words per minute")
                        }
                        if let wpm = bucket.m4gWPM {
                            LineMark(
                                x: .value("Date", bucket.start, unit: ChartAxes.unit(for: report.period)),
                                y: .value("WPM", wpm),
                                series: .value("Keyboard", "M4G")
                            )
                            .foregroundStyle(StatsPalette.m4gTyped)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(
                                x: .value("Date", bucket.start, unit: ChartAxes.unit(for: report.period)),
                                y: .value("WPM", wpm)
                            )
                            .foregroundStyle(StatsPalette.m4gTyped)
                            .symbol(.square)
                            .symbolSize(24)
                            .accessibilityLabel("\(ChartAxes.readoutDate(bucket.start, period: report.period)), M4G")
                            .accessibilityValue("\(Int(wpm.rounded())) words per minute")
                        }
                    }
                    if let selected {
                        RuleMark(x: .value("Selected", selected.start, unit: ChartAxes.unit(for: report.period)))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                            .accessibilityHidden(true)
                    }
                }
                .chartOverlay { proxy in
                    BucketHoverOverlay(proxy: proxy, buckets: report.buckets, selected: $selected)
                }
                .statsAxes(report: report)
                .frame(height: 160)
            }
        }
    }
}

// MARK: - Single-series charts

/// A bar chart of one measure per bucket with an average line and scrubbing.
private struct SingleSeriesBarCard: View {
    let title: String
    let report: StatsReport
    let color: Color
    let valueName: String
    let value: (StatsBucket) -> Double?
    let format: (Double) -> String
    let summary: String
    var asLine = false
    var fixedPercentScale = false
    /// Counts: keep at least 0–4 on the axis so ticks stay whole numbers.
    var integerValues = false
    @State private var selected: StatsBucket?

    var body: some View {
        StatsCard(title: title, summary: readout ?? summary) {
            Chart {
                ForEach(report.buckets) { bucket in
                    if let number = value(bucket) {
                        if asLine {
                            LineMark(
                                x: .value("Date", bucket.start, unit: ChartAxes.unit(for: report.period)),
                                y: .value(valueName, number)
                            )
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .accessibilityLabel(ChartAxes.readoutDate(bucket.start, period: report.period))
                            .accessibilityValue(format(number))
                        } else {
                            BarMark(
                                x: .value("Date", bucket.start, unit: ChartAxes.unit(for: report.period)),
                                y: .value(valueName, number),
                                width: .ratio(0.7)
                            )
                            .foregroundStyle(color)
                            .cornerRadius(2)
                            .opacity(selected == nil || selected?.start == bucket.start ? 1 : 0.45)
                            .accessibilityLabel(ChartAxes.readoutDate(bucket.start, period: report.period))
                            .accessibilityValue(format(number))
                        }
                    }
                }
                if let selected {
                    RuleMark(x: .value("Selected", selected.start, unit: ChartAxes.unit(for: report.period)))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                        .accessibilityHidden(true)
                }
            }
            .chartYScale(domain: fixedPercentScale ? 0...max(0.05, maxValue) : 0...max(integerValues ? 4 : 1, maxValue))
            .chartOverlay { proxy in
                BucketHoverOverlay(proxy: proxy, buckets: report.buckets, selected: $selected)
            }
            .statsAxes(report: report, percent: fixedPercentScale)
            .frame(height: 130)
            .accessibilityChartDescriptor(
                StatsChartDescriptor(
                    title: title,
                    summary: summary,
                    valueName: valueName,
                    series: [(title, report.buckets.compactMap { bucket in value(bucket).map { (bucket.start, $0) } })],
                    period: report.period
                )
            )
        }
    }

    private var maxValue: Double {
        report.buckets.compactMap(value).max() ?? 0
    }

    private var readout: String? {
        guard let selected else { return nil }
        let text = value(selected).map(format) ?? "no data"
        return "\(ChartAxes.readoutDate(selected.start, period: report.period)): \(text)."
    }
}

private struct ChordsUsedChartCard: View {
    let report: StatsReport

    var body: some View {
        let trackedDays = max(1, report.buckets.filter { report.isTracked($0) }.count)
        let perBucket = Double(report.chordTotals.chordsUsed) / Double(trackedDays)
        let unit = report.period.bucketsByMonth ? "month" : "day"
        SingleSeriesBarCard(
            title: report.period.bucketsByMonth ? "Chords per month" : "Chords per day",
            report: report,
            color: StatsPalette.chorded,
            valueName: "chords",
            value: { report.isTracked($0) ? Double($0.chordsUsed) : nil },
            format: { "\(Int($0).formatted()) chords" },
            summary: report.attributionStart == nil
                ? "Appears once the recorder sees your Master Forge."
                : "\(report.chordTotals.chordsUsed.formatted()) chords, about \(Int(perBucket.rounded()).formatted()) a \(unit) since tracking began.",
            integerValues: true
        )
    }
}

private struct TyposChartCard: View {
    let report: StatsReport

    var body: some View {
        SingleSeriesBarCard(
            title: "Typo rate",
            report: report,
            color: StatsPalette.typos,
            valueName: "typos per 100 words",
            value: { $0.typoRate },
            format: { String(format: "%.1f typos per 100 words", $0 * 100) },
            summary: "\(report.totals.typoWords.formatted()) misspelled words, \(String(format: "%.1f", (report.totals.typoRate ?? 0) * 100)) per 100. A chord never misspells.",
            asLine: true,
            fixedPercentScale: true
        )
    }
}

private struct TypingTimeChartCard: View {
    let report: StatsReport

    var body: some View {
        let share = report.totals.handTypingMs > 0 ? report.totals.unchordedMs / report.totals.handTypingMs : 0
        SingleSeriesBarCard(
            title: "Time typing by hand",
            report: report,
            color: StatsPalette.time,
            valueName: "minutes",
            value: { $0.handTypingMs / 60_000 },
            format: { "\(Int($0.rounded())) minutes typing letter by letter" },
            summary: "\(StatsTabView<EmptyView>.duration(report.totals.handTypingMs)) in total; \(StatsTabView<EmptyView>.percent(share)) of it on words with no chord."
        )
    }
}

private struct ChordsAddedChartCard: View {
    let report: StatsReport

    var body: some View {
        SingleSeriesBarCard(
            title: "Chords added",
            report: report,
            color: StatsPalette.library,
            valueName: "chords added",
            value: { Double($0.chordsAdded) },
            format: { "\(Int($0)) chords added" },
            summary: "\(report.totals.chordsAdded) new chords from Grow, Advisor and Add in the \(report.period.displayName).",
            integerValues: true
        )
    }
}

// MARK: - Speed

/// Speed per input method, grouped the way you type: other keyboards on one
/// side, the Master Forge on the other with chords, letters and the blend.
private struct SpeedSection: View {
    let report: StatsReport
    @State private var selected: StatsBucket?

    private var totals: StatsBucket { report.totals }

    private var summary: String {
        if let selected {
            let parts = [
                selected.m4gBlendedWPM.map { "M4G \(Int($0.rounded())) WPM" },
                selected.chordSpeedWPM.map { "chords \(Int($0.rounded()))" },
                selected.m4gLetterSpeedWPM.map { "letters \(Int($0.rounded()))" },
                selected.keyboardSpeedWPM.map { "other keyboards \(Int($0.rounded()))" }
            ].compactMap { $0 }
            return "\(ChartAxes.readoutDate(selected.start, period: report.period)): " + (parts.isEmpty ? "no typing" : parts.joined(separator: " · ")) + "."
        }
        switch (totals.chordSpeedWPM, totals.m4gLetterSpeedWPM) {
        case (let chords?, let letters?) where letters > 0:
            let ratio = chords / letters
            return String(format: "On the M4G your chords run at %.1f× your letter-by-letter speed. Every word you move from letters to a chord speeds up the blend.", ratio)
        default:
            return "Real typing speed, pauses over 3 seconds left out."
        }
    }

    var body: some View {
        StatsCard(title: "Speed", summary: summary) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    SpeedGroup(title: "Other keyboard", systemImage: "keyboard") {
                        SpeedFigure(label: "Letter by letter", wpm: totals.keyboardSpeedWPM, color: StatsPalette.keyboard, prominent: true)
                    }
                    .frame(maxWidth: 200)
                    SpeedGroup(title: "Master Forge", systemImage: "keyboard.badge.ellipsis") {
                        HStack(alignment: .top, spacing: 18) {
                            SpeedFigure(label: "Blended", wpm: totals.m4gBlendedWPM, color: StatsPalette.blended, prominent: true)
                            SpeedFigure(label: "Chorded", wpm: totals.chordSpeedWPM, color: StatsPalette.chorded, prominent: false)
                            SpeedFigure(label: "Letter by letter", wpm: totals.m4gLetterSpeedWPM, color: StatsPalette.m4gTyped, prominent: false)
                        }
                    }
                }

                Chart {
                    ForEach(report.buckets) { bucket in
                        line(bucket, value: bucket.keyboardSpeedWPM, series: "Other keyboard", color: StatsPalette.keyboard)
                        line(bucket, value: bucket.m4gBlendedWPM, series: "M4G blended", color: StatsPalette.blended)
                        line(bucket, value: bucket.chordSpeedWPM, series: "Chorded", color: StatsPalette.chorded)
                        line(bucket, value: bucket.m4gLetterSpeedWPM, series: "M4G letter by letter", color: StatsPalette.m4gTyped)
                    }
                    if let selected {
                        RuleMark(x: .value("Selected", selected.start, unit: ChartAxes.unit(for: report.period)))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                            .accessibilityHidden(true)
                    }
                }
                .chartForegroundStyleScale([
                    "Other keyboard": StatsPalette.keyboard,
                    "M4G blended": StatsPalette.blended,
                    "Chorded": StatsPalette.chorded,
                    "M4G letter by letter": StatsPalette.m4gTyped
                ])
                .chartLegend(position: .top, alignment: .leading)
                .chartOverlay { proxy in
                    BucketHoverOverlay(proxy: proxy, buckets: report.buckets, selected: $selected)
                }
                .statsAxes(report: report)
                .frame(height: 170)

                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ChartContentBuilder
    private func line(_ bucket: StatsBucket, value: Double?, series: String, color: Color) -> some ChartContent {
        if let value {
            LineMark(
                x: .value("Date", bucket.start, unit: ChartAxes.unit(for: report.period)),
                y: .value("WPM", value),
                series: .value("Method", series)
            )
            .foregroundStyle(by: .value("Method", series))
            .lineStyle(StrokeStyle(lineWidth: series == "M4G blended" ? 3 : 2))
            PointMark(
                x: .value("Date", bucket.start, unit: ChartAxes.unit(for: report.period)),
                y: .value("WPM", value)
            )
            .foregroundStyle(by: .value("Method", series))
            .symbolSize(16)
            .accessibilityLabel("\(ChartAxes.readoutDate(bucket.start, period: report.period)), \(series)")
            .accessibilityValue("\(Int(value.rounded())) words per minute")
        }
    }

    private var footnote: String {
        var text = "Each word and its space, timed from the end of the previous word; pauses over 3 seconds are left out. 1 word = 5 characters."
        if let start = report.speedTrackingStart {
            text += " Speed tracking since \(start.formatted(.dateTime.month(.abbreviated).day()))."
        }
        return text
    }
}

private struct SpeedGroup<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SpeedFigure: View {
    let label: String
    let wpm: Double?
    let color: Color
    let prominent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(wpm.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(prominent ? .title : .title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text("WPM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Accuracy

/// Typos and chord misfires are both errors, but they have different fixes,
/// so they are counted side by side rather than lumped together.
private struct AccuracySection: View {
    @ObservedObject var model: AppModel
    let report: StatsReport
    @State private var selected: StatsBucket?

    private var totals: StatsBucket { report.totals }

    private var summary: String {
        if let selected {
            let typo = selected.typoRate.map { String(format: "%.1f typos per 100 hand-typed words", $0 * 100) } ?? "no hand typing"
            let misfire = selected.misfireRate.map { String(format: "%.1f misfires per 100 chords", $0 * 100) } ?? "no chords"
            return "\(ChartAxes.readoutDate(selected.start, period: report.period)): \(typo), \(misfire)."
        }
        var text = "\(totals.typoWords.formatted()) typos and \(totals.misfires.formatted()) chord misfires."
        if let first = report.topMisfires.first {
            text += " \(first.word) misfires most; a different chord for it may fire more reliably."
        }
        return text
    }

    var body: some View {
        StatsCard(title: "Accuracy", summary: summary) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    AccuracyFigure(
                        label: "Typos",
                        value: totals.typoRate,
                        unit: "per 100 words typed by hand",
                        color: StatsPalette.typos
                    )
                    AccuracyFigure(
                        label: "Chord misfires",
                        value: totals.misfireRate,
                        unit: "per 100 chords · \(totals.deletedMisfires) deleted, \(totals.garbledMisfires) garbled",
                        color: StatsPalette.misfires
                    )
                    AccuracyFigure(
                        label: "Corrections",
                        value: totals.backspaceRate,
                        unit: "backspaces per 100 keys, including ones the M4G sends",
                        color: nil
                    )
                }

                Chart {
                    ForEach(report.buckets) { bucket in
                        if let typo = bucket.typoRate {
                            LineMark(
                                x: .value("Date", bucket.start, unit: ChartAxes.unit(for: report.period)),
                                y: .value("Rate", typo),
                                series: .value("Kind", "Typos")
                            )
                            .foregroundStyle(StatsPalette.typos)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .accessibilityLabel("\(ChartAxes.readoutDate(bucket.start, period: report.period)), typos")
                            .accessibilityValue(String(format: "%.1f per 100 hand-typed words", typo * 100))
                        }
                        if report.isTracked(bucket), let misfire = bucket.misfireRate {
                            LineMark(
                                x: .value("Date", bucket.start, unit: ChartAxes.unit(for: report.period)),
                                y: .value("Rate", misfire),
                                series: .value("Kind", "Misfires")
                            )
                            .foregroundStyle(StatsPalette.misfires)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(
                                x: .value("Date", bucket.start, unit: ChartAxes.unit(for: report.period)),
                                y: .value("Rate", misfire)
                            )
                            .foregroundStyle(StatsPalette.misfires)
                            .symbol(.diamond)
                            .symbolSize(22)
                            .accessibilityLabel("\(ChartAxes.readoutDate(bucket.start, period: report.period)), misfires")
                            .accessibilityValue(String(format: "%.1f per 100 chords", misfire * 100))
                        }
                    }
                    if let selected {
                        RuleMark(x: .value("Selected", selected.start, unit: ChartAxes.unit(for: report.period)))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                            .accessibilityHidden(true)
                    }
                }
                .chartYScale(domain: 0...max(0.05, maxRate))
                .chartOverlay { proxy in
                    BucketHoverOverlay(proxy: proxy, buckets: report.buckets, selected: $selected)
                }
                .statsAxes(report: report, percent: true)
                .frame(height: 140)

                HStack(spacing: 14) {
                    LegendItem(color: StatsPalette.typos, label: "Typos", value: nil)
                    LegendItem(color: StatsPalette.misfires, label: "Chord misfires", value: nil)
                }

                if !report.topMisfires.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Most misfired chords")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(report.topMisfires) { misfire in
                            HStack(spacing: 8) {
                                Text(misfire.word)
                                    .font(.callout)
                                    .frame(width: 120, alignment: .leading)
                                if let input = misfire.chordInput {
                                    ActionTokenRow(tokens: input).fixedSize()
                                } else {
                                    Text("letters, no chord")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(misfire.count)×")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if misfire.chordInput != nil {
                                    Button("Re-map") { model.openAdvisor(for: misfire.word) }
                                        .buttonStyle(.link)
                                        .font(.caption)
                                        .help("Find a different chord for \(misfire.word) in Advisor")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var maxRate: Double {
        report.buckets.flatMap { [$0.typoRate, report.isTracked($0) ? $0.misfireRate : nil] }.compactMap { $0 }.max() ?? 0
    }
}

private struct AccuracyFigure: View {
    let label: String
    let value: Double?
    let unit: String
    let color: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let color {
                    Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value.map { String(format: "%.1f", $0 * 100) } ?? "—")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

