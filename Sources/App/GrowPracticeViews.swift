import Charts
import Library
import SwiftUI

// MARK: - Grow

/// Batch chord planning: the words that cost the most time without a chord,
/// each with a conflict-free chord, staged together and committed once.
struct GrowTabView: View {
    @ObservedObject var model: AppModel
    @State private var mergeWordsText = ""
    @State private var mergeTargetText = ""

    private var stagedWords: Set<String> { model.stagedOutputs() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Plan", selection: $model.growMode) {
                ForEach(AppModel.GrowMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)

            if model.growMode == .phrases {
                PhraseGrowView(model: model)
            } else {
                wordsBody
            }
        }
    }

    private var wordsBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            controls
            if model.isPlanningGrowth && !model.hasLoadedGrowthPlan {
                ProgressView("Finding the words that slow you down…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.growthPlan.items.isEmpty {
                PanelEmptyState(
                    icon: "checkmark.seal",
                    title: "Nothing to add right now",
                    detail: "Every word you typed at least \(GrowthPlanner.minimumFrequency) times in the last \(model.growthWindowDays) days already has a chord."
                )
            } else {
                list
            }
        }
        .task {
            if !model.hasLoadedGrowthPlan {
                await model.loadGrowthPlan()
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            PanelMetric(
                title: "Time on unchorded words",
                value: model.growthPlan.uncoveredTimeShare.formatted(.percent.precision(.fractionLength(0))),
                detail: "of letter-by-letter typing"
            )
            PanelMetric(
                title: "Ready to add",
                value: "\(model.growthPlan.items.count)",
                detail: "\(model.growthPlan.items.filter { $0.category == .ending }.count) are word endings"
            )
            PanelMetric(
                title: "Selected",
                value: "\(model.growthSelection.count)",
                detail: "stage, then Commit"
            )
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Period", selection: Binding(
                get: { model.growthWindowDays },
                set: { model.setGrowthWindowDays($0) }
            )) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

            if model.isPlanningGrowth {
                ProgressView().controlSize(.small)
            }

            Spacer()

            Menu("Select") {
                Button("Top 5") { model.selectTopGrowthItems(5) }
                Button("Top 10") { model.selectTopGrowthItems(10) }
                Button("Top 25") { model.selectTopGrowthItems(25) }
                Divider()
                Button("None") { model.growthSelection.removeAll() }
            }
            .fixedSize()

            Button("Stage \(model.growthSelection.count)") {
                model.stageSelectedGrowthItems()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.growthSelection.isEmpty)
            .help("Stage the selected chords. Review them in Staged, then Commit to write them to the M4G in one go.")
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(model.growthPlan.items) { item in
                    GrowRow(model: model, item: item, isStaged: stagedWords.contains(item.word))
                }
            } header: {
                Text("Ranked by time lost typing each word letter by letter")
            } footer: {
                footer
            }

            mergedSection

            if !model.growthPlan.skippedWords.isEmpty {
                Section("Skipped") {
                    ForEach(model.growthPlan.skippedWords, id: \.self) { word in
                        HStack {
                            Text(word)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore") {
                                Task { await model.unskipGrowthWord(word) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var mergedSection: some View {
        Section {
            ForEach(model.growthPlan.aliases.sorted { $0.key < $1.key }, id: \.key) { word, target in
                HStack {
                    Text(word)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(target)
                    Spacer()
                    Button("Unmerge") {
                        Task { await model.unmergeWord(word) }
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 6) {
                TextField("Pieces, e.g. zelv, zel", text: $mergeWordsText)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("Real word", text: $mergeTargetText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                Button("Merge") {
                    let words = mergeWordsText.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                    let target = mergeTargetText
                    Task {
                        await model.mergeWords(words, into: target)
                        mergeWordsText = ""
                        mergeTargetText = ""
                    }
                }
                .disabled(mergeWordsText.isEmpty || mergeTargetText.isEmpty)
            }
        } header: {
            Text("Merged words")
        } footer: {
            Text("Autocomplete only sends the letters you typed, so a word you finish with Tab shows up as its first few letters. Merged pieces and misspellings count toward the real word. Pieces you finish with Tab or → at least half the time are merged automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Learn new chords 3–5 at a time in Practice. Adding many at once is fine; drilling them in small groups is what makes them stick.")
            if model.growthPlan.arabicWordCount > 0 {
                Text("\(model.growthPlan.arabicWordCount) Arabic words (\(model.growthPlan.arabicOccurrences) uses) are not listed. The M4G sends key codes, so an Arabic chord only works with a matching macOS input source.")
            }
            if !model.growthPlan.typos.isEmpty {
                Text("\(model.growthPlan.typos.count) likely typos, such as \(model.growthPlan.typos.prefix(3).map { "\($0.typo) → \($0.intended)" }.joined(separator: ", ")), are left out. Practice lists them.")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }
}

private struct GrowRow: View {
    @ObservedObject var model: AppModel
    let item: GrowthItem
    let isStaged: Bool

    private var isSelected: Binding<Bool> {
        Binding(
            get: { model.growthSelection.contains(item.word) },
            set: { _ in model.toggleGrowthSelection(item) }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isStaged)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.word)
                        .font(.headline)
                    if item.category == .ending, let base = item.baseWord {
                        PanelBadge(text: "\(base) + ending", tint: .purple)
                            .help("Extends your \(base) chord with one marker key. Your device's suffix modifiers can also produce this word.")
                    }
                    if isStaged {
                        PanelBadge(text: "Staged", tint: .green)
                    }
                }

                HStack(spacing: 6) {
                    if let candidate = model.chosenCandidate(for: item) {
                        ActionTokenRow(tokens: candidate.inputKeys.map(ChordInputValidator.displayToken))
                            .fixedSize()
                    }
                    if item.candidates.count > 1 {
                        Menu {
                            ForEach(Array(item.candidates.enumerated()), id: \.offset) { index, candidate in
                                Button {
                                    model.growthCandidateChoice[item.word] = index
                                } label: {
                                    Text(candidate.inputKeys.map(ChordInputValidator.displayToken).joined(separator: " + "))
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Choose another chord")
                    }
                }

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if !item.mergedWords.isEmpty {
                    Text("Also counts \(item.mergedWords.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let target = item.possibleCompletionOf {
                    let pieces = Array(Set(item.completionFragments + [item.word])).sorted()
                    Button {
                        Task { await model.mergeWords(pieces, into: target) }
                    } label: {
                        Label(
                            "Start of \(target)? Count \(pieces.joined(separator: ", ")) as \(target)",
                            systemImage: "arrow.triangle.merge"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.link)
                    .help("You probably type the first letters and finish with autocomplete.")
                }
            }

            Spacer(minLength: 0)

            Button {
                Task { await model.skipGrowthWord(item) }
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Don't suggest \(item.word) again")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isStaged else { return }
            model.toggleGrowthSelection(item)
        }
    }

    private var detail: String {
        let seconds = item.timeCostMs / 1_000
        let lost = seconds >= 60
            ? String(format: "%.1f min", seconds / 60)
            : String(format: "%.0f s", seconds)
        return "\(item.frequency)× · \(String(format: "%.1f", item.avgMs / 1_000)) s each · \(lost) typing it"
    }
}

// MARK: - Phrases

/// Phrase chords: one chord for two or three words you write together.
private struct PhraseGrowView: View {
    @ObservedObject var model: AppModel

    private var stagedOutputs: Set<String> { model.stagedOutputs() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PanelMetric(
                    title: "Phrases worth a chord",
                    value: "\(model.phrasePlan.count)",
                    detail: "seen \(4)+ times in \(model.growthWindowDays) days"
                )
                PanelMetric(
                    title: "Selected",
                    value: "\(model.phraseSelection.count)",
                    detail: "stage, then Commit"
                )
            }
            HStack(spacing: 8) {
                Text("Phrase chords use the first letter of each word plus space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isPlanningPhrases {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Stage \(model.phraseSelection.count)") {
                    model.stageSelectedPhrases()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.phraseSelection.isEmpty)
            }
            if model.phrasePlan.isEmpty {
                PanelEmptyState(
                    icon: "text.quote",
                    title: model.isPlanningPhrases ? "Looking for phrases…" : "No phrases yet",
                    detail: "Chordsmith counts two- and three-word phrases from now on, only as counts. Phrases you write at least 4 times show up here, usually within a day or two."
                )
            } else {
                List {
                    ForEach(model.phrasePlan) { item in
                        row(item)
                    }
                }
                .listStyle(.plain)
            }
        }
        .task {
            if !model.hasLoadedPhrasePlan {
                await model.loadPhrasePlan()
            }
        }
    }

    private func row(_ item: PhraseItem) -> some View {
        let isStaged = stagedOutputs.contains(item.phrase)
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.phraseSelection.contains(item.phrase) },
                set: { selected in
                    if selected { model.phraseSelection.insert(item.phrase) } else { model.phraseSelection.remove(item.phrase) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(isStaged)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.phrase)
                        .font(.headline)
                    if isStaged {
                        PanelBadge(text: "Staged", tint: .green)
                    }
                }
                HStack(spacing: 6) {
                    if let candidate = model.chosenCandidate(for: item) {
                        ActionTokenRow(tokens: candidate.inputKeys.map(ChordInputValidator.displayToken)).fixedSize()
                    }
                    if item.candidates.count > 1 {
                        Menu {
                            ForEach(Array(item.candidates.enumerated()), id: \.offset) { index, candidate in
                                Button(candidate.inputKeys.map(ChordInputValidator.displayToken).joined(separator: " + ")) {
                                    model.phraseCandidateChoice[item.phrase] = index
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Choose another chord")
                    }
                }
                Text("\(item.frequency)× · \(item.handFrequency) typed fully by hand · one chord instead of \(item.wordCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Practice

struct PracticeTabView: View {
    @ObservedObject var model: AppModel
    @State private var drill: DrillSession?
    @State private var speedWords: [String]?

    var body: some View {
        Group {
            if let speedWords {
                SpeedDrillView(
                    words: speedWords,
                    onFinish: { result, bigrams in await model.saveSpeedDrill(result, bigrams: bigrams) },
                    onAgain: { Task { self.speedWords = await model.makeSpeedDrillWords() } },
                    onClose: { self.speedWords = nil }
                )
                .id(speedWords)
            } else if let drill {
                DrillView(session: drill) {
                    self.drill = nil
                    Task { await model.loadPracticeReport() }
                }
            } else {
                overview
            }
        }
        .task {
            if !model.hasLoadedPracticeReport {
                await model.loadPracticeReport()
            }
            await model.loadSpeedData()
        }
    }

    private var report: PracticeReport { model.practiceReport }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if report.lacksM4GAttribution {
                attributionBanner
            }

            HStack(spacing: 8) {
                PanelMetric(title: "Chorded", value: "\(report.chordedWords)", detail: "last \(report.windowDays) days")
                PanelMetric(title: "Typed on M4G", value: "\(report.m4gTypedWords)", detail: "letter by letter")
                PanelMetric(title: "Other keyboard", value: "\(report.keyboardWords)", detail: "letter by letter")
            }

            LetterSpeedCard(model: model) {
                Task { speedWords = await model.makeSpeedDrillWords() }
            }

            HStack(spacing: 8) {
                Text("Drill 5 at a time:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Forgotten") {
                    drill = DrillSession(title: "Chords you forgot", items: report.forgotten.compactMap(DrillItem.init))
                }
                .disabled(report.forgotten.isEmpty)
                Button("New chords") {
                    drill = DrillSession(title: "New chords", items: report.learning.map(DrillItem.init))
                }
                .disabled(report.learning.isEmpty)
                Button("Typos") {
                    drill = DrillSession(title: "Typos a chord prevents", items: report.typos.compactMap(DrillItem.init))
                }
                .disabled(report.typos.isEmpty)
                Spacer()
                Button {
                    Task { await model.loadPracticeReport() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            List {
                Section {
                    if report.learning.isEmpty {
                        Text("Chords you add in Grow, Advisor or Add show up here until you mark them learned.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(report.learning) { learning in
                        learningRow(learning)
                    }
                } header: {
                    Text(report.learnedCount > 0 ? "New chords to adopt · \(report.learnedCount) learned" : "New chords to adopt")
                }

                Section("You have a chord but typed it letter by letter") {
                    if report.forgotten.isEmpty {
                        Text("Nothing yet this week.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(report.forgotten.prefix(40)) { forgotten in
                        forgottenRow(forgotten)
                    }
                }

                if !report.typos.isEmpty {
                    Section("Typos a chord would have prevented") {
                        ForEach(report.typos.prefix(20)) { typo in
                            HStack(spacing: 8) {
                                Text(typo.typo)
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(typo.intended)
                                    .font(.headline)
                                if let input = typo.intendedChordInput {
                                    ActionTokenRow(tokens: input).fixedSize()
                                }
                                Spacer()
                                Text("\(typo.frequency)×")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var attributionBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Chorded and typed words were counted together until now")
                    .font(.caption.weight(.semibold))
                Text("Before this update the recorder could not match keys to the Master Forge, so every word counted as \"other keyboard\". From now on chorded, M4G-typed and laptop-typed words are counted separately.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func forgottenRow(_ forgotten: ForgottenChord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(forgotten.word)
                        .font(.headline)
                    if let input = forgotten.chordInputs.first {
                        ActionTokenRow(tokens: input).fixedSize()
                    }
                }
                Text(forgottenDetail(forgotten))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if forgotten.typedFrequency + forgotten.chordedFrequency > 0 {
                ChordRateBar(rate: forgotten.chordRate)
                    .frame(width: 60)
                    .help("\(Int((forgotten.chordRate * 100).rounded()))% chorded")
            }
        }
        .padding(.vertical, 2)
    }

    private func forgottenDetail(_ forgotten: ForgottenChord) -> String {
        var parts = ["typed \(forgotten.typedFrequency)×"]
        if forgotten.m4gTypedFrequency > 0 {
            parts.append("\(forgotten.m4gTypedFrequency) on M4G")
        }
        parts.append("chorded \(forgotten.chordedFrequency)×")
        parts.append(String(format: "%.1f s each by hand", forgotten.typedAvgMs / 1_000))
        return parts.joined(separator: " · ")
    }

    private func learningRow(_ learning: LearningChord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(learning.word)
                        .font(.headline)
                    ActionTokenRow(tokens: learning.input).fixedSize()
                }
                Text("Added \(learning.chord.createdAt.formatted(.relative(presentation: .named))) · chorded \(learning.chordedSinceAdded)× · typed \(learning.typedSinceAdded)×")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.setChordLearned(learning.chord, learned: true) }
            } label: {
                Label("Learned", systemImage: "checkmark")
            }
            .controlSize(.small)
            .help("Stop listing this chord")
        }
        .padding(.vertical, 2)
    }
}

private struct ChordRateBar: View {
    let rate: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(Color.green)
                    .frame(width: max(0, min(1, rate)) * proxy.size.width)
            }
        }
        .frame(height: 5)
        .padding(.top, 6)
    }
}

// MARK: - Letter speed

/// Letter-by-letter speed on the M4G: the floor that decides whether an
/// unchorded word sends you back to the laptop keyboard.
private struct LetterSpeedCard: View {
    @ObservedObject var model: AppModel
    let startDrill: () -> Void

    private var summary: String {
        let usage = model.todayUsage
        let speed = usage.speed
        var parts: [String] = []
        if let letters = speed.m4gLetterSpeedWPM ?? usage.m4gWPM {
            parts.append("Today on the M4G, letter by letter: \(Int(letters.rounded())) WPM")
        } else {
            parts.append("No M4G letter-by-letter typing today yet")
        }
        if let chords = speed.chordSpeedWPM {
            parts.append("chords \(Int(chords.rounded()))")
        }
        if let blended = speed.m4gBlendedWPM {
            parts.append("blended \(Int(blended.rounded()))")
        }
        if let keyboard = speed.keyboardSpeedWPM ?? usage.keyboardWPM {
            parts.append("other keyboards \(Int(keyboard.rounded()))")
        }
        if let last = model.speedDrillHistory.last {
            parts.append("last drill \(Int(last.wpm.rounded())) WPM at \(Int((last.accuracy * 100).rounded()))% accuracy")
        }
        return parts.joined(separator: " · ") + "."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Letter-by-letter speed")
                        .font(.headline)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Speed drill", action: startDrill)
                    .buttonStyle(.borderedProminent)
                    .help("About 14 of your own words, weighted toward your slowest letter pairs. Type them on the M4G without chords.")
            }
            if model.speedDrillHistory.count >= 2 {
                Chart {
                    ForEach(Array(model.speedDrillHistory.enumerated()), id: \.element.id) { index, result in
                        LineMark(x: .value("Drill", index + 1), y: .value("WPM", result.wpm))
                            .foregroundStyle(StatsPalette.m4gTyped)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("Drill", index + 1), y: .value("WPM", result.wpm))
                            .foregroundStyle(StatsPalette.m4gTyped)
                            .symbolSize(18)
                            .accessibilityLabel("Drill \(index + 1), \(result.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                            .accessibilityValue("\(Int(result.wpm.rounded())) words per minute, \(Int((result.accuracy * 100).rounded())) percent accurate")
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(StatsPalette.grid)
                        AxisValueLabel()
                    }
                }
                .frame(height: 70)
            }
            if !model.slowBigrams.isEmpty {
                HStack(spacing: 6) {
                    Text("Slowest letter pairs:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(model.slowBigrams.prefix(6)) { timing in
                        Text("\(timing.bigram) \(Int(timing.averageMs.rounded())) ms")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(StatsPalette.m4gTyped.opacity(0.14), in: Capsule())
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Type a line of your own words on the M4G, letter by letter. Measures WPM,
/// accuracy and the time between every pair of letters.
private struct SpeedDrillView: View {
    let words: [String]
    let onFinish: (SpeedDrillResult, [String: (totalMs: Double, count: Int)]) async -> Void
    let onAgain: () -> Void
    let onClose: () -> Void

    @State private var typed = ""
    @State private var log: [(character: Character, time: Date)] = []
    @State private var result: SpeedDrillResult?
    @State private var chordBursts = 0
    @FocusState private var focused: Bool

    private var target: String { words.joined(separator: " ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed drill")
                        .font(.headline)
                    Text("Type on your Master Forge, letter by letter, no chords. The timer starts on your first key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: onClose)
            }

            if let result {
                summary(result)
            } else {
                Text(progressText)
                    .font(.system(size: 22, weight: .regular, design: .monospaced))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Type: \(target)")
                TextField("Start typing…", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 18, design: .monospaced))
                    .focused($focused)
                    .onChange(of: typed) { value in record(value) }
                    .onSubmit { finish() }
            }
            Spacer(minLength: 0)
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var progressText: AttributedString {
        var text = AttributedString()
        let targetCharacters = Array(target)
        let typedCharacters = Array(typed)
        for (index, character) in targetCharacters.enumerated() {
            var piece = AttributedString(String(character))
            if index < typedCharacters.count {
                if typedCharacters[index] == character {
                    piece.foregroundColor = .primary
                } else {
                    piece.foregroundColor = .red
                    piece.underlineStyle = .single
                }
            } else if index == typedCharacters.count {
                piece.foregroundColor = .primary
                piece.backgroundColor = StatsPalette.m4gTyped.opacity(0.25)
            } else {
                piece.foregroundColor = .secondary
            }
            text += piece
        }
        return text
    }

    private func summary(_ result: SpeedDrillResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading) {
                    Text("\(Int(result.wpm.rounded())) WPM")
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    Text("letter by letter")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text("\(Int((result.accuracy * 100).rounded()))%")
                        .font(.system(.title, design: .rounded).weight(.semibold))
                    Text("accuracy")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !result.slowBigrams.isEmpty {
                Text("Slowest letter pairs this run: " + result.slowBigrams.map { "\($0.bigram) \(Int($0.averageMs.rounded())) ms" }.joined(separator: ", "))
                    .font(.callout)
            }
            if chordBursts > 0 {
                Label("\(chordBursts) chord output\(chordBursts == 1 ? "" : "s") detected; those letters were left out of the timing.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Next drills lean on your slowest pairs. A few short drills a day beat one long one; accuracy first, speed follows.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Again with new words", action: onAgain)
                    .buttonStyle(.borderedProminent)
                Button("Done", action: onClose)
            }
        }
    }

    private func record(_ value: String) {
        let now = Date()
        if value.count < log.count {
            log.removeLast(log.count - value.count)
        } else if value.count > log.count {
            for character in value.dropFirst(log.count) {
                log.append((character, now))
            }
        }
        if value.count >= target.count {
            finish()
        }
    }

    private func finish() {
        guard result == nil, let first = log.first, let last = log.last else { return }
        let targetCharacters = Array(target)
        let typedCharacters = Array(typed)
        let correct = zip(typedCharacters, targetCharacters).filter { $0 == $1 }.count
        let accuracy = Double(correct) / Double(max(targetCharacters.count, typedCharacters.count))

        // Letters that arrived within a few milliseconds of each other came
        // from a chord, not from fingers; leave them out of the timing.
        var clean: [(character: Character, time: Date)] = []
        var bursts = 0
        for (index, entry) in log.enumerated() {
            let isBurst = index > 0 && entry.time.timeIntervalSince(log[index - 1].time) < 0.012
            if isBurst {
                bursts += 1
                continue
            }
            if index < targetCharacters.count, entry.character == targetCharacters[index] {
                clean.append(entry)
            }
        }
        chordBursts = bursts > 2 ? bursts : 0

        let elapsed = max(last.time.timeIntervalSince(first.time), 1)
        let wpm = (Double(correct) / 5) / (elapsed / 60)
        let bigrams = SpeedDrillBuilder.bigramTimings(typed: clean)
        let slow = bigrams
            .map { BigramTiming(bigram: $0.key, averageMs: $0.value.totalMs / Double($0.value.count), count: $0.value.count) }
            .sorted { $0.averageMs > $1.averageMs }
            .prefix(5)
        let drillResult = SpeedDrillResult(
            wpm: wpm,
            accuracy: accuracy,
            characters: typedCharacters.count,
            slowBigrams: Array(slow)
        )
        result = drillResult
        Task { await onFinish(drillResult, bigrams) }
    }
}

// MARK: - Drill

struct DrillItem: Identifiable, Hashable {
    var id: String { word }
    let word: String
    let input: [String]

    init(word: String, input: [String]) {
        self.word = word
        self.input = input
    }

    init?(_ forgotten: ForgottenChord) {
        guard let input = forgotten.chordInputs.first else { return nil }
        self.init(word: forgotten.word, input: input)
    }

    init(_ learning: LearningChord) {
        self.init(word: learning.word.lowercased(), input: learning.input)
    }

    init?(_ typo: TypoFinding) {
        guard let input = typo.intendedChordInput else { return nil }
        self.init(word: typo.intended, input: input)
    }
}

struct DrillSession: Hashable {
    let title: String
    let items: [DrillItem]
}

/// Five words at a time: see the word (and the chord, until you know it),
/// chord it into the field, and get timing back.
private struct DrillView: View {
    let session: DrillSession
    let onClose: () -> Void

    private static let roundSize = 5

    @State private var roundStart = 0
    @State private var index = 0
    @State private var typed = ""
    @State private var showChord = true
    @State private var shownAt = Date()
    @State private var results: [DrillResult] = []
    @State private var misses = 0
    @FocusState private var fieldFocused: Bool

    private struct DrillResult: Identifiable {
        let id = UUID()
        let word: String
        let milliseconds: Double
        let misses: Int
    }

    private var round: [DrillItem] {
        Array(session.items.dropFirst(roundStart).prefix(Self.roundSize))
    }

    private var isRoundDone: Bool { index >= round.count }
    private var hasMoreRounds: Bool { roundStart + Self.roundSize < session.items.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.headline)
                    Text("Round \(roundStart / Self.roundSize + 1) of \(max(1, (session.items.count + Self.roundSize - 1) / Self.roundSize)) · chord the word into the field")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: onClose)
            }

            if isRoundDone {
                roundSummary
            } else {
                prompt
            }

            if !results.isEmpty {
                Divider()
                ForEach(results) { result in
                    HStack {
                        Text(result.word)
                        Spacer()
                        if result.misses > 0 {
                            Text("\(result.misses) miss\(result.misses == 1 ? "" : "es")")
                                .foregroundStyle(.orange)
                        }
                        Text(String(format: "%.2f s", result.milliseconds / 1_000))
                            .monospacedDigit()
                            .foregroundStyle(result.milliseconds < 1_500 ? .green : .secondary)
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .onAppear { restartTimer() }
    }

    private var prompt: some View {
        let item = round[index]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(index + 1) / \(round.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Show chord", isOn: $showChord)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
            }
            Text(item.word)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
            if showChord {
                ActionTokenRow(tokens: item.input).fixedSize()
            } else {
                Text("Chord hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Chord it here", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($fieldFocused)
                .onChange(of: typed) { value in
                    check(value, against: item)
                }
        }
    }

    private var roundSummary: some View {
        let roundResults = results.suffix(round.count)
        let average = roundResults.isEmpty ? 0 : roundResults.map(\.milliseconds).reduce(0, +) / Double(roundResults.count)
        let perMinute = average > 0 ? 60_000 / average : 0
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(format: "Round done · %.2f s average · %.0f chords/min", average / 1_000, perMinute))
                .font(.headline)
            Text("Repeat the round until you're past 30 chords per minute with the chord hidden, then move on to the next five.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Repeat round") {
                    index = 0
                    showChord = false
                    restartTimer()
                }
                if hasMoreRounds {
                    Button("Next 5") {
                        roundStart += Self.roundSize
                        index = 0
                        showChord = true
                        restartTimer()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func check(_ value: String, against item: DrillItem) {
        let attempt = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if attempt == item.word.lowercased() {
            results.append(
                DrillResult(
                    word: item.word,
                    milliseconds: Date().timeIntervalSince(shownAt) * 1_000,
                    misses: misses
                )
            )
            advance()
        } else if value.last?.isWhitespace == true, !attempt.isEmpty {
            // A finished chord that produced the wrong word.
            misses += 1
            typed = ""
        }
    }

    private func advance() {
        typed = ""
        misses = 0
        index += 1
        restartTimer()
    }

    private func restartTimer() {
        shownAt = Date()
        DispatchQueue.main.async { fieldFocused = true }
    }
}

// MARK: - Shared panel pieces

struct PanelMetric: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.headline.monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct PanelBadge: View {
    let text: String
    var tint: Color = .blue

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct PanelEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
