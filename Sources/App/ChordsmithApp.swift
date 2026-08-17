@preconcurrency import AppKit
import Device
import Engine
import KeyboardShortcuts
import Library
import SwiftUI

@main
struct ChordsmithApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
                .frame(width: 440, height: 460)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var quickChordPanel: NSPanel?
    private var lastControlPress: Date?
    private var globalControlMonitor: Any?
    private var localControlMonitor: Any?
    private let doubleTapControlThreshold: TimeInterval = 0.3

    override init() {
        do {
            model = try AppModel()
        } catch {
            fatalError("Failed to create app model: \(error)")
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupKeyboardShortcuts()
        setupDoubleTapControl()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        if let globalControlMonitor {
            NSEvent.removeMonitor(globalControlMonitor)
            self.globalControlMonitor = nil
        }
        if let localControlMonitor {
            NSEvent.removeMonitor(localControlMonitor)
            self.localControlMonitor = nil
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshLaunchAtLoginStatus()
        model.resumeInputObservationIfNeeded()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: "Chordsmith")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover?.behavior = .transient
        popover?.contentSize = NSSize(width: 560, height: 620)
        popover?.contentViewController = NSHostingController(rootView: RootView(model: model))
    }

    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.togglePopover()
        }
        KeyboardShortcuts.onKeyUp(for: .quickAdvisor) { [weak self] in
            self?.showPopover(tab: .advisor)
        }
        KeyboardShortcuts.onKeyUp(for: .quickAdd) { [weak self] in
            self?.showQuickChordPanel()
        }
    }

    private func setupDoubleTapControl() {
        globalControlMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleControlFlagsChanged(event)
        }
        localControlMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleControlFlagsChanged(event)
            return event
        }
    }

    private func handleControlFlagsChanged(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .control else { return }

        let now = Date()
        if let lastControlPress,
           now.timeIntervalSince(lastControlPress) <= doubleTapControlThreshold {
            self.lastControlPress = nil
            Task { @MainActor in
                showQuickChordPanel()
            }
            return
        }
        lastControlPress = now
    }

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover(tab: PanelTab? = nil) {
        guard let button = statusItem?.button, let popover else { return }
        quickChordPanel?.close()
        if let tab {
            model.selectedTab = tab
        }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showQuickChordPanel() {
        popover?.performClose(nil)

        let panel: NSPanel
        if let quickChordPanel {
            panel = quickChordPanel
        } else {
            panel = QuickChordPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.title = "Quick Chords"
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isReleasedWhenClosed = false
            quickChordPanel = panel
        }

        panel.contentViewController = NSHostingController(
            rootView: QuickChordPanelView(model: model) { [weak self] in
                self?.quickChordPanel?.close()
            }
        )
        centerQuickChordPanel(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func centerQuickChordPanel(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2 + 90
        )
        panel.setFrameOrigin(origin)
    }
}

private final class QuickChordPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel", default: .init(.space, modifiers: [.command, .shift]))
    static let quickAdvisor = Self("quickAdvisor", default: .init(.space, modifiers: [.command, .option]))
    static let quickAdd = Self("quickAdd", default: .init(.a, modifiers: [.command, .shift]))
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @StateObject private var addController = QuickChordAddController()
    @State private var addFocusToken = 0
    @State private var advisorWord = ""
    @State private var selectedChordID: UUID?
    @State private var selectedAdvisorCandidateID: String?
    @FocusState private var focusedField: FocusField?

    private enum FocusField: Hashable {
        case librarySearch
        case advisorWord
    }

    private var filteredChords: [ChordEntry] {
        guard !searchText.isEmpty else { return model.chords }
        return ChordSearch.ranked(model.chords, query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView(selection: $model.selectedTab) {
                libraryTab
                    .tabItem { Label("Library", systemImage: "books.vertical") }
                    .tag(PanelTab.library)
                advisorTab
                    .tabItem { Label("Advisor", systemImage: "wand.and.stars") }
                    .tag(PanelTab.advisor)
                addTab
                    .tabItem { Label("Add", systemImage: "plus.circle") }
                    .tag(PanelTab.add)
                stagedTab
                    .tabItem { Label("Staged", systemImage: "tray.full") }
                    .tag(PanelTab.staged)
                suggestionsTab
                    .tabItem { Label("Suggestions", systemImage: "sparkles") }
                    .tag(PanelTab.suggestions)
                usageTab
                    .tabItem { Label("Usage", systemImage: "chart.bar.xaxis") }
                    .tag(PanelTab.usage)
            }
            .padding(12)
        }
        .frame(width: 560, height: 620)
        .background(LocalShortcutMonitor { event in
            handleShortcut(event)
        })
        .onAppear {
            focusDefaultField(for: model.selectedTab)
        }
        .onChange(of: model.selectedTab) { tab in
            focusDefaultField(for: tab)
        }
        .alert("Error", isPresented: Binding(
            get: { model.lastError != nil },
            set: { newValue in
                if !newValue {
                    model.lastError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                model.lastError = nil
            }
        } message: {
            Text(model.lastError ?? "Unknown error")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chordsmith")
                        .font(.title2.weight(.semibold))
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                Button("Import JSON") {
                    Task { await model.importChordJSON() }
                }
                Button("Export JSON") {
                    Task { await model.exportChordJSON() }
                }
                Button("Exit") {
                    NSApp.terminate(nil)
                }
            }

            if let device = model.deviceSource {
                HStack {
                    Label("\(device.deviceName) • \(device.chordCount) chords", systemImage: "cable.connector")
                    if !model.pendingDeviceMutations.isEmpty {
                        Label("\(model.pendingDeviceMutations.count) pending", systemImage: "tray.full")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if !model.pendingDeviceMutations.isEmpty {
                        Button("Retry Device Sync") {
                            Task { await model.syncPrimaryDevice() }
                        }
                    }
                }
                .font(.caption)
            }

            if !model.stagedChanges.isEmpty {
                HStack {
                    Label("\(model.stagedChanges.count) staged", systemImage: "tray.full")
                    Spacer()
                    Button("Undo") {
                        model.undoLastStagedChange()
                    }
                    Button("Commit") {
                        Task { await model.commitStagedChanges() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .font(.caption)
            }

            if let progress = model.bootstrapProgress {
                ProgressView(value: Double(progress.current), total: Double(progress.total))
            }
        }
        .padding(14)
    }

    private var libraryTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search chords", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .librarySearch)

            List(selection: $selectedChordID) {
                ForEach(filteredChords, id: \.id) { chord in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chord.output)
                                .font(.headline)
                            ActionTokenRow(tokens: chord.displayInput.isEmpty ? chord.inputKeys : chord.displayInput)
                            if !chord.actionFlags.isEmpty {
                                ActionTokenRow(tokens: chord.actionFlags.map(\.rawValue).sorted(), tint: .orange)
                            }
                            if chord.plainOutput == nil, !chord.phraseTokens.isEmpty {
                                ActionTokenRow(tokens: chord.phraseTokens, tint: .purple)
                            }
                            Text("\(chord.profile.displayName) • \(chord.deploymentTarget.displayName) • \(chord.source)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if !chord.enabled {
                                Text("Disabled")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.16), in: Capsule())
                            }
                        }
                        Spacer()
                        starButton(for: chord)
                        Button(role: .destructive) {
                            Task { await model.deleteChord(chord) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                    .tag(chord.id)
                }
            }
            .listStyle(.plain)
        }
    }

    private var advisorTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("New word", text: $advisorWord)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .advisorWord)
                    .onSubmit {
                        Task { await model.adviseChord(for: advisorWord) }
                    }
                Button("Find Chords") {
                    Task { await model.adviseChord(for: advisorWord) }
                }
                .buttonStyle(.borderedProminent)
            }

            List(selection: $selectedAdvisorCandidateID) {
                if !model.advisorExistingChords.isEmpty {
                    Section("Current Chords") {
                        ForEach(model.advisorExistingChords) { chord in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text(chord.output)
                                            .font(.headline)
                                        Text(chord.normalizedInput)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    ActionTokenRow(tokens: chord.displayInput.isEmpty ? chord.inputKeys : chord.displayInput)
                                    if !chord.actionFlags.isEmpty {
                                        ActionTokenRow(tokens: chord.actionFlags.map(\.rawValue).sorted(), tint: .orange)
                                    }
                                    if chord.plainOutput == nil, !chord.phraseTokens.isEmpty {
                                        ActionTokenRow(tokens: chord.phraseTokens, tint: .purple)
                                    }
                                    Text("\(chord.profile.displayName) • \(chord.deploymentTarget.displayName) • \(chord.source)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                starButton(for: chord)
                                Button(role: .destructive) {
                                    Task { await model.deleteChord(chord) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Stage delete")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Suggestions") {
                    ForEach(model.advisorCandidates) { candidate in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                ActionTokenRow(tokens: candidate.inputKeys)
                                Spacer()
                                Text(String(format: "%.1f", candidate.score))
                                    .font(.caption.monospacedDigit())
                                Button("Stage") {
                                    Task { await model.acceptAdvisorCandidate(candidate, word: advisorWord) }
                                }
                            }
                            if !candidate.softReasons.isEmpty {
                                Text(candidate.softReasons.joined(separator: " "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(candidate.id)
                    }
                }

                if !model.advisorRejectedCandidates.isEmpty {
                    Section("Rejected") {
                        ForEach(model.advisorRejectedCandidates) { candidate in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    ActionTokenRow(tokens: candidate.inputKeys, tint: .red)
                                    Spacer()
                                    Text(String(format: "%.1f", candidate.score))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(candidate.hardFailures.joined(separator: " "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func starButton(for chord: ChordEntry) -> some View {
        Button {
            Task { await model.toggleChordStarred(chord) }
        } label: {
            Image(systemName: chord.isStarred ? "star.fill" : "star")
                .foregroundStyle(chord.isStarred ? .yellow : .secondary)
        }
        .buttonStyle(.borderless)
        .help(chord.isStarred ? "Unstar chord" : "Star chord")
    }

    private var addTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuickChordAddView(
                model: model,
                controller: addController,
                showsCancel: true,
                contentPadding: 0,
                focusToken: addFocusToken,
                initialFocus: .output,
                onCancel: {
                    addController.reset()
                    addFocusToken += 1
                },
                onCommitSuccess: {
                    addController.reset()
                    addFocusToken += 1
                }
            )
            Spacer(minLength: 0)
        }
    }

    private var stagedTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(model.stagedChanges.count) pending changes")
                    .font(.headline)
                Spacer()
                Button("Undo Last") {
                    model.undoLastStagedChange()
                }
                .disabled(model.stagedChanges.isEmpty)
                Button("Commit") {
                    Task { await model.commitStagedChanges() }
                }
                .disabled(model.stagedChanges.isEmpty)
                .buttonStyle(.borderedProminent)
            }

            List {
                ForEach(model.stagedChanges) { change in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(change.kind.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(change.kind == .delete ? .red : .blue)
                        Text(change.chord.output)
                            .font(.headline)
                        ActionTokenRow(tokens: change.chord.displayInput.isEmpty ? change.chord.inputKeys : change.chord.displayInput)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
        }
    }

    private var suggestionsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Suggestion Profile", selection: $model.suggestionProfile) {
                    ForEach([ErgonomicProfile.ansiQwerty, .cc2A1, .ansiColemak, .ansiColemakDH], id: \.self) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                Button("Rebuild") {
                    Task { await model.regenerateSuggestions() }
                }
            }

            List {
                ForEach(model.suggestions, id: \.id) { suggestion in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(suggestion.word)
                                .font(.headline)
                            Spacer()
                            Text("Priority \(Int(suggestion.priorityScore))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(suggestion.candidates) { candidate in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(candidate.inputKeys.joined(separator: "+"))
                                        .font(.system(.subheadline, design: .monospaced))
                                    Spacer()
                                    if suggestion.acceptedChordId != nil {
                                        Label("Use this chord", systemImage: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    } else {
                                        Text(String(format: "%.1f", candidate.score))
                                            .font(.caption)
                                        Button("Software") {
                                            Task { await model.acceptSuggestion(suggestion, candidate: candidate, target: .software) }
                                        }
                                        Button("Both") {
                                            Task { await model.acceptSuggestion(suggestion, candidate: candidate, target: .both) }
                                        }
                                    }
                                }
                                if !candidate.softReasons.isEmpty {
                                    Text(candidate.softReasons.joined(separator: " "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
        }
        .onChange(of: model.suggestionProfile) { _ in
            Task {
                await model.refresh()
            }
        }
    }

    private var usageTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label(
                        model.inputObserver.isRunning ? "Recorder running" : "Recorder paused",
                        systemImage: model.inputObserver.isRunning ? "record.circle" : "pause.circle"
                    )
                    .foregroundStyle(model.inputObserver.isRunning ? .green : .secondary)
                    Text(model.inputObserver.attributionStatusText)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.inputObserver.needsInputMonitoringPermission {
                    Button("Input Monitoring…") {
                        model.openInputMonitoringSettings()
                    }
                }
                Button(model.inputObserver.isRunning ? "Pause" : "Resume") {
                    model.toggleInputObservation()
                }
                Button("Refresh") {
                    Task { await model.loadUsageReport() }
                }
            }
            .font(.caption)

            HStack(spacing: 10) {
                Picker(
                    "Language",
                    selection: Binding(
                        get: { model.usageLanguageFilter },
                        set: { model.setUsageLanguageFilter($0) }
                    )
                ) {
                    Text("All languages").tag(Optional<WordLanguage>.none)
                    Text("English").tag(Optional(WordLanguage.english))
                    Text("العربية").tag(Optional(WordLanguage.arabic))
                    Text("Mixed").tag(Optional(WordLanguage.mixed))
                }
                .labelsHidden()

                Picker(
                    "Period",
                    selection: Binding(
                        get: { model.usageCoverageDays },
                        set: { model.setUsageCoverageDays($0) }
                    )
                ) {
                    Text("7 days").tag(Optional(7))
                    Text("30 days").tag(Optional(30))
                    Text("All time").tag(Optional<Int>.none)
                }
                .labelsHidden()
                Spacer()
                Text("Exact enabled M4G outputs count as covered")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    usageMetric("Today", words: model.usageOverview.wordsToday, chords: model.usageOverview.chordsToday)
                    usageMetric("7 days", words: model.usageOverview.words7Days, chords: model.usageOverview.chords7Days)
                }
                GridRow {
                    usageMetric("30 days", words: model.usageOverview.words30Days, chords: model.usageOverview.chords30Days)
                    usageMetric("All time", words: model.usageOverview.wordsAllTime, chords: model.usageOverview.chordsAllTime)
                }
            }

            HStack(spacing: 8) {
                coverageMetric(
                    "Chord coverage",
                    value: model.wordCoverageReport.coverageRate.formatted(.percent.precision(.fractionLength(1))),
                    detail: "\(model.wordCoverageReport.coveredOccurrences) of \(model.wordCoverageReport.totalOccurrences) uses"
                )
                coverageMetric(
                    "Covered words",
                    value: "\(model.wordCoverageReport.coveredUniqueWords)",
                    detail: "of \(model.wordCoverageReport.uniqueWords) unique"
                )
                coverageMetric(
                    "Needs a chord",
                    value: "\(model.wordCoverageReport.uncoveredUniqueWords)",
                    detail: "\(model.wordCoverageReport.uncoveredOccurrences) uses"
                )
            }

            List {
                Section("Most used without an M4G chord") {
                    if model.wordCoverageReport.uncoveredWords.isEmpty {
                        Text("No uncovered words in this filter.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.wordCoverageReport.uncoveredWords.prefix(15)) { usage in
                            coverageWordRow(usage)
                        }
                    }
                }

                Section("Most used with an M4G chord") {
                    if model.wordCoverageReport.coveredWords.isEmpty {
                        Text("No covered words in this filter.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.wordCoverageReport.coveredWords.prefix(15)) { usage in
                            coverageWordRow(usage)
                        }
                    }
                }

                Section("Two-key impact") {
                    if model.twoKeyChordImpact.isEmpty {
                        Text("No two-key usage recorded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.twoKeyChordImpact.prefix(12)) { impact in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(impact.chord.output)
                                        .font(.headline)
                                    ActionTokenRow(tokens: impact.chord.displayInput.isEmpty ? impact.chord.inputKeys : impact.chord.displayInput)
                                    Text(usageDetail(
                                        total: impact.totalFrequency,
                                        seven: impact.frequency7Days,
                                        thirty: impact.frequency30Days,
                                        confidence: impact.confidence,
                                        ambiguity: impact.ambiguityCount
                                    ))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(impact.totalFrequency)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                Section("Recent chords") {
                    if model.recentChordUsage.isEmpty {
                        Text("No chord usage recorded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.recentChordUsage.prefix(10)) { usage in
                            usageRow(
                                title: usage.output,
                                subtitle: "\(usage.source.displayName) • \(usage.confidence.displayName) • \(usage.day)",
                                frequency: usage.frequency
                            )
                        }
                    }
                }

                Section("Recent words") {
                    if model.recentWordUsage.isEmpty {
                        Text("No word usage recorded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.recentWordUsage.prefix(10)) { usage in
                            usageRow(
                                title: usage.word,
                                subtitle: "\(usage.language.displayName) • \(usage.source.displayName) • \(usage.day)",
                                frequency: usage.frequency
                            )
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .onAppear {
            Task { await model.loadUsageReport() }
        }
    }

    private func usageMetric(_ title: String, words: Int, chords: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text("\(words) words")
            Text("\(chords) chords")
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func coverageMetric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func coverageWordRow(_ usage: WordCoverageStat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(usage.word)
                    .font(.headline)
                    .environment(\.layoutDirection, usage.language == .arabic ? .rightToLeft : .leftToRight)
                HStack(spacing: 5) {
                    Text(usage.language.displayName)
                    if let chord = usage.matchingChords.first {
                        Text("•")
                        Text(chord.normalizedInput)
                            .fontDesign(.monospaced)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(usage.frequency)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func usageRow(title: String, subtitle: String, frequency: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(frequency)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func usageDetail(
        total: Int,
        seven: Int,
        thirty: Int,
        confidence: ChordUsageConfidence?,
        ambiguity: Int
    ) -> String {
        var parts = ["7d \(seven)", "30d \(thirty)", "total \(total)"]
        if let confidence {
            parts.append(confidence.displayName)
        }
        if ambiguity > 1 {
            parts.append("\(ambiguity) matching outputs")
        }
        return parts.joined(separator: " • ")
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = modifiers.contains(.command)
        let hasOption = modifiers.contains(.option)
        let hasControl = modifiers.contains(.control)
        let hasShift = modifiers.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if model.selectedTab == .add {
            if addController.handleCapture(event) {
                addFocusToken += 1
                return true
            }

            if !hasCommand, !hasOption, !hasControl, !hasShift {
                if event.keyCode == 125, !addController.quickCandidates.isEmpty {
                    addController.cycleQuickCandidate(delta: 1)
                    addFocusToken += 1
                    return true
                }
                if event.keyCode == 126, !addController.quickCandidates.isEmpty {
                    addController.cycleQuickCandidate(delta: -1)
                    addFocusToken += 1
                    return true
                }
                if event.keyCode == 36 {
                    saveMenuQuickChord()
                    return true
                }
            }
        }

        if hasCommand, !hasOption, !hasControl, !hasShift {
            switch key {
            case "1":
                model.selectedTab = .library
                return true
            case "2":
                model.selectedTab = .advisor
                return true
            case "3":
                model.selectedTab = .add
                return true
            case "4":
                model.selectedTab = .staged
                return true
            case "5":
                model.selectedTab = .suggestions
                return true
            case "6":
                model.selectedTab = .usage
                return true
            case "f", "k":
                focusDefaultField(for: model.selectedTab)
                return true
            case "s":
                Task { await model.commitStagedChanges() }
                return true
            case "z" where !model.stagedChanges.isEmpty:
                model.undoLastStagedChange()
                return true
            default:
                break
            }

            if event.keyCode == 36 {
                runPrimaryAction()
                return true
            }
        }

        if !hasCommand, !hasOption, !hasControl, !hasShift {
            if event.keyCode == 51 {
                return stageSelectedDelete()
            }
            if event.keyCode == 53 {
                closePopover()
                return true
            }
        }

        return false
    }

    private func focusDefaultField(for tab: PanelTab) {
        DispatchQueue.main.async {
            switch tab {
            case .library:
                focusedField = .librarySearch
            case .advisor:
                focusedField = .advisorWord
            case .add:
                focusedField = nil
                addFocusToken += 1
            case .staged, .suggestions, .usage:
                focusedField = nil
            }
        }
    }

    private func runPrimaryAction() {
        switch model.selectedTab {
        case .library:
            focusDefaultField(for: .library)
        case .advisor:
            if focusedField == .advisorWord || model.advisorCandidates.isEmpty {
                Task { await model.adviseChord(for: advisorWord) }
            } else if let candidate = selectedAdvisorCandidate ?? model.advisorCandidates.first {
                Task { await model.acceptAdvisorCandidate(candidate, word: advisorWord) }
            } else {
                Task { await model.adviseChord(for: advisorWord) }
            }
        case .add:
            saveMenuQuickChord()
        case .staged:
            Task { await model.commitStagedChanges() }
        case .suggestions:
            Task { await model.regenerateSuggestions() }
        case .usage:
            Task { await model.loadUsageReport() }
        }
    }

    private var selectedAdvisorCandidate: Candidate? {
        guard let selectedAdvisorCandidateID else { return nil }
        return model.advisorCandidates.first { $0.id == selectedAdvisorCandidateID }
    }

    private func saveMenuQuickChord() {
        Task {
            await addController.quickSave(model: model) {
                addController.reset()
                addFocusToken += 1
            }
        }
    }

    private func stageSelectedDelete() -> Bool {
        guard model.selectedTab == .library,
              focusedField != .librarySearch,
              let selectedChordID,
              let chord = model.chords.first(where: { $0.id == selectedChordID }) else {
            return false
        }
        Task { await model.deleteChord(chord) }
        return true
    }

    private func closePopover() {
        NSApp.keyWindow?.close()
    }
}

struct LocalShortcutMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: handler)
    }

    func makeNSView(context: Context) -> NSView {
        let view = ShortcutMonitorHostView(frame: .zero)
        view.coordinator = context.coordinator
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator: @unchecked Sendable {
        var handler: (NSEvent) -> Bool
        var isActive = false
        private var monitor: Any?
        private var keyObserver: NSObjectProtocol?
        private var resignObserver: NSObjectProtocol?

        init(handler: @escaping (NSEvent) -> Bool) {
            self.handler = handler
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isActive,
                      self.handler(event) else {
                    return event
                }
                return nil
            }
        }

        func bind(to window: NSWindow?) {
            unbindWindow()
            guard let window else { return }
            isActive = true

            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.isActive = true
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.isActive = false
            }
        }

        func uninstall() {
            unbindWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func unbindWindow() {
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
                self.keyObserver = nil
            }
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
                self.resignObserver = nil
            }
            isActive = false
        }

        deinit {
            uninstall()
        }
    }

    final class ShortcutMonitorHostView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.bind(to: window)
        }
    }
}

struct ActionTokenRow: View {
    let tokens: [String]
    var tint: Color = .blue

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    Text(token)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.14), in: Capsule())
                        .foregroundStyle(tint)
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Quick Panel") {
                KeyboardShortcuts.Recorder(for: .togglePanel)
                KeyboardShortcuts.Recorder(for: .quickAdvisor)
                KeyboardShortcuts.Recorder(for: .quickAdd)
            }

            Section("Engine") {
                Toggle("Enable software chording", isOn: $model.engineEnabled)
                Picker("Software profile", selection: $model.activeSoftwareProfile) {
                    Text(ErgonomicProfile.ansiQwerty.displayName).tag(ErgonomicProfile.ansiQwerty)
                    Text(ErgonomicProfile.ansiColemak.displayName).tag(ErgonomicProfile.ansiColemak)
                    Text(ErgonomicProfile.ansiColemakDH.displayName).tag(ErgonomicProfile.ansiColemakDH)
                }
            }

            Section("Startup") {
                Toggle(
                    "Launch Chordsmith at login",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLoginEnabled($0) }
                    )
                )
                .disabled(!model.canManageLaunchAtLogin)
                Text(model.launchAtLoginStatusText)
                    .font(.caption)
                    .foregroundStyle(model.launchAtLoginNeedsApproval ? .orange : .secondary)
                if model.launchAtLoginNeedsApproval {
                    Button("Open Login Items Settings") {
                        model.openLoginItemSettings()
                    }
                }
            }

            Section("Excluded Apps") {
                TextField("com.apple.Terminal, com.apple.iTerm2", text: $model.excludedBundleIDsText, axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
                Text("Comma-separated bundle identifiers. The engine passes through untouched while these apps are frontmost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Save Settings") {
                Task { await model.saveSettings() }
            }
        }
        .padding(16)
    }
}
