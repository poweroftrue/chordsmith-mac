@preconcurrency import AppKit
import Device
import Engine
import KeyboardShortcuts
import Library
import SwiftUI

@main
struct CharaworderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
                .frame(width: 420, height: 340)
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
        if let globalControlMonitor {
            NSEvent.removeMonitor(globalControlMonitor)
            self.globalControlMonitor = nil
        }
        if let localControlMonitor {
            NSEvent.removeMonitor(localControlMonitor)
            self.localControlMonitor = nil
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: "Charaworder")
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
    @State private var addInput = ""
    @State private var addOutput = ""
    @State private var addProfile: ErgonomicProfile = .ansiQwerty
    @State private var addTarget: DeploymentTarget = .software
    @State private var advisorWord = ""
    @State private var selectedChordID: UUID?
    @State private var selectedAdvisorCandidateID: String?
    @FocusState private var focusedField: FocusField?

    private enum FocusField: Hashable {
        case librarySearch
        case advisorWord
        case addInput
        case addOutput
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
                    Text("Charaworder")
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
                Button("Settings") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
                        }
                        Spacer()
                        starButton(for: chord)
                        Toggle("", isOn: Binding(
                            get: { chord.enabled },
                            set: { newValue in Task { await model.setChordEnabled(chord, enabled: newValue) } }
                        ))
                        .labelsHidden()
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
        Form {
            Section("Chord Input") {
                TextField("a,s,d or a+s+d", text: $addInput)
                    .focused($focusedField, equals: .addInput)
                Text("Use normalized physical key tokens. Commas and plus signs are both accepted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                TextField("Expanded text or key combo", text: $addOutput)
                    .focused($focusedField, equals: .addOutput)
            }

            Section("Routing") {
                Picker("Profile", selection: $addProfile) {
                    ForEach(ErgonomicProfile.allCases.filter { $0 != .cc2A1 || addTarget != .software }, id: \.self) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                Picker("Deployment", selection: $addTarget) {
                    ForEach(DeploymentTarget.allCases, id: \.self) { target in
                        Text(target.displayName).tag(target)
                    }
                }
            }

            Button("Save Chord") {
                saveAddChord()
            }
        }
        .formStyle(.grouped)
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
                                    Text(String(format: "%.1f", candidate.score))
                                        .font(.caption)
                                    Button("Software") {
                                        Task { await model.acceptSuggestion(suggestion, candidate: candidate, target: .software) }
                                    }
                                    Button("Both") {
                                        Task { await model.acceptSuggestion(suggestion, candidate: candidate, target: .both) }
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

    private func handleShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = modifiers.contains(.command)
        let hasOption = modifiers.contains(.option)
        let hasControl = modifiers.contains(.control)
        let hasShift = modifiers.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased()

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
                focusedField = .addInput
            case .staged, .suggestions:
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
            saveAddChord()
        case .staged:
            Task { await model.commitStagedChanges() }
        case .suggestions:
            Task { await model.regenerateSuggestions() }
        }
    }

    private var selectedAdvisorCandidate: Candidate? {
        guard let selectedAdvisorCandidateID else { return nil }
        return model.advisorCandidates.first { $0.id == selectedAdvisorCandidateID }
    }

    private func saveAddChord() {
        Task {
            await model.addChord(input: addInput, output: addOutput, profile: addProfile, deploymentTarget: addTarget)
            addInput = ""
            addOutput = ""
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
