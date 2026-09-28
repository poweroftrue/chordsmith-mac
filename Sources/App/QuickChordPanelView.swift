@preconcurrency import AppKit
import Library
import SwiftUI

enum QuickChordOutputMode: String, CaseIterable, Identifiable {
    case plain = "Plain"
    case actions = "Actions"

    var id: String { rawValue }
}

enum QuickChordEditorInitialFocus {
    case input
    case output
}

private enum QuickChordInputSource {
    case empty
    case advisor
    case manual
}

@MainActor
final class QuickChordAddController: ObservableObject {
    @Published var editingChord: ChordEntry?
    @Published var inputText = ""
    @Published var outputText = ""
    @Published var outputMode: QuickChordOutputMode = .plain
    @Published var phraseActions: [Int] = []
    @Published var phraseActionText = ""
    @Published var captureActive = false
    @Published var isCommitting = false
    @Published var localError: String?
    @Published var quickCandidates: [Candidate] = []
    @Published var selectedQuickCandidateID: String?
    @Published var isAdvisorLoading = false
    @Published var quickAdvisorError: String?

    private var quickAdvisorTask: Task<Void, Never>?
    private var inputSource: QuickChordInputSource = .empty
    private var isApplyingAdvisorInput = false

    func quickChords(in model: AppModel) -> [ChordEntry] {
        model.chords.filter { chord in
            chord.profile == .cc2A1
                && (chord.deploymentTarget == .device || chord.deploymentTarget == .both)
        }
    }

    func baseValidation(in model: AppModel) -> ChordInputValidation {
        model.validateQuickDeviceChordInput(inputText, replacing: editingChord)
    }

    func replacementChord(in model: AppModel) -> ChordEntry? {
        guard editingChord == nil,
              let conflictID = baseValidation(in: model).conflictingChordID else {
            return nil
        }
        return quickChords(in: model).first { $0.id == conflictID }
    }

    func validation(in model: AppModel) -> ChordInputValidation {
        if let replacementChord = replacementChord(in: model),
           outputMode == .actions || AppModel.isQuickEditablePlainDeviceChord(replacementChord) {
            return model.validateQuickDeviceChordInput(inputText, replacing: replacementChord)
        }
        return baseValidation(in: model)
    }

    func saveButtonTitle(in model: AppModel) -> String {
        if editingChord != nil {
            return "Save"
        }
        if replacementChord(in: model) != nil {
            return "Replace"
        }
        return "Add"
    }

    func isSaveDisabled(in model: AppModel) -> Bool {
        if isCommitting || !validation(in: model).isValid {
            return true
        }
        switch outputMode {
        case .plain:
            return outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .actions:
            return phraseActions.isEmpty
        }
    }

    func outputTextChanged(model: AppModel) {
        guard outputMode == .plain else { return }
        scheduleQuickAdvisor(model: model)
    }

    func outputModeChanged(_ newValue: QuickChordOutputMode, model: AppModel) {
        if newValue == .actions {
            if phraseActions.isEmpty, !outputText.isEmpty {
                phraseActions = ActionCodec.phraseActions(forPlainText: outputText)
            }
            clearQuickAdvisor()
        } else {
            if outputText.isEmpty, let plainText = ActionCatalog.plainText(for: phraseActions) {
                outputText = plainText
            }
            scheduleQuickAdvisor(model: model)
        }
    }

    func inputTextChanged(_ newValue: String) {
        guard !isApplyingAdvisorInput else { return }
        inputSource = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .manual
    }

    func startAdd(prefilledInput: String = "", prefilledOutput: String = "", model: AppModel) {
        reset()
        inputText = prefilledInput
        outputText = prefilledOutput
        outputMode = .plain
        inputSource = prefilledInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .manual
        scheduleQuickAdvisor(model: model, immediate: true)
    }

    func startEdit(_ chord: ChordEntry) {
        reset()
        editingChord = chord
        inputText = (chord.displayInput.isEmpty ? chord.inputKeys : chord.displayInput)
            .map(ChordInputValidator.displayToken)
            .joined(separator: "+")
        if AppModel.isQuickEditablePlainDeviceChord(chord) {
            outputMode = .plain
            outputText = chord.plainOutput ?? chord.output
            phraseActions = []
        } else {
            outputMode = .actions
            outputText = chord.plainOutput ?? ""
            phraseActions = chord.rawPhraseActions
                ?? chord.encodedPhrase.map(ActionCodec.parsePhraseActions)
                ?? chord.phraseTokens.compactMap { ActionCatalog.code(for: $0) }
        }
        phraseActionText = ""
        captureActive = false
        inputSource = .manual
        clearQuickAdvisor()
    }

    func reset() {
        clearQuickAdvisor()
        editingChord = nil
        inputText = ""
        outputText = ""
        outputMode = .plain
        phraseActions = []
        phraseActionText = ""
        captureActive = false
        localError = nil
        inputSource = .empty
    }

    func cancelTasks() {
        quickAdvisorTask?.cancel()
    }

    func scheduleQuickAdvisor(model: AppModel, immediate: Bool = false) {
        quickAdvisorTask?.cancel()
        quickAdvisorError = nil

        guard editingChord == nil, outputMode == .plain else {
            clearQuickAdvisor()
            return
        }

        let word = outputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard word.count >= 2 else {
            clearQuickAdvisor(clearAdvisorInput: true)
            return
        }

        isAdvisorLoading = true
        quickAdvisorTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
            guard !Task.isCancelled else { return }

            do {
                let candidates = try await model.quickAdvisorCandidates(for: word, limit: 5)
                guard !Task.isCancelled else { return }

                isAdvisorLoading = false
                quickCandidates = candidates
                quickAdvisorError = nil
                selectedQuickCandidateID = candidates.first?.id

                if let first = candidates.first {
                    applyQuickCandidate(first, shouldFocusInput: false)
                } else if inputSource == .advisor {
                    applyAdvisorInput("")
                    inputSource = .empty
                }
            } catch {
                guard !Task.isCancelled else { return }
                isAdvisorLoading = false
                quickCandidates = []
                selectedQuickCandidateID = nil
                quickAdvisorError = error.localizedDescription
            }
        }
    }

    func clearQuickAdvisor(clearAdvisorInput: Bool = false) {
        quickAdvisorTask?.cancel()
        isAdvisorLoading = false
        quickCandidates = []
        selectedQuickCandidateID = nil
        quickAdvisorError = nil
        if clearAdvisorInput, inputSource == .advisor {
            applyAdvisorInput("")
            inputSource = .empty
        }
    }

    func applyQuickCandidate(_ candidate: Candidate, shouldFocusInput: Bool = true) {
        selectedQuickCandidateID = candidate.id
        guard shouldAutoApplyAdvisorCandidate || shouldFocusInput else { return }
        applyAdvisorInput(candidate.inputKeys.joined(separator: "+"))
        inputSource = .advisor
        captureActive = false
    }

    func cycleQuickCandidate(delta: Int) {
        guard !quickCandidates.isEmpty else { return }
        let currentIndex = selectedQuickCandidateID.flatMap { selectedID in
            quickCandidates.firstIndex { $0.id == selectedID }
        } ?? 0
        let nextIndex = (currentIndex + delta + quickCandidates.count) % quickCandidates.count
        applyQuickCandidate(quickCandidates[nextIndex])
    }

    func handleCapture(_ event: NSEvent) -> Bool {
        guard captureActive,
              event.keyCode != 36,
              event.keyCode != 48,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let chars = event.charactersIgnoringModifiers?.lowercased(),
              !chars.isEmpty else {
            return false
        }

        var tokens = ChordInputValidator.tokens(from: inputText, compactRepeatsUseDup: true)
        var capturedToken = false
        for char in chars where !char.isWhitespace {
            let token = String(char)
            guard ActionCatalog.code(for: token) != nil else { continue }
            tokens.append(tokens.contains(token) ? "dup" : token)
            capturedToken = true
        }
        guard capturedToken else { return false }
        inputText = tokens.joined(separator: "+")
        selectedQuickCandidateID = nil
        inputSource = inputText.isEmpty ? .empty : .manual
        return true
    }

    /// The suggestion you picked, when it takes keys from a barely used
    /// chord and the keys field still holds exactly those keys.
    var activeReclaim: (candidate: Candidate, reclaim: ChordReclaim)? {
        guard editingChord == nil, outputMode == .plain,
              let selected = quickCandidates.first(where: { $0.id == selectedQuickCandidateID }),
              let reclaim = selected.reclaim else { return nil }
        let typed = Set(ChordInputValidator.tokens(from: inputText, compactRepeatsUseDup: true).map { $0.lowercased() })
        return typed == Set(selected.inputKeys.map { $0.lowercased() }) ? (selected, reclaim) : nil
    }

    func quickSave(model: AppModel, onSuccess: @escaping () -> Void) async {
        guard !isCommitting else { return }
        if let active = activeReclaim {
            isCommitting = true
            let word = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            let succeeded = await model.quickCommitReclaim(active.reclaim, keys: active.candidate.inputKeys, word: word)
            isCommitting = false
            if succeeded { onSuccess() } else { localError = model.lastError ?? "Couldn't move the old chord." }
            return
        }
        let replacement = editingChord ?? replacementChord(in: model)
        if outputMode == .plain, let replacement, !AppModel.isQuickEditablePlainDeviceChord(replacement) {
            localError = "Quick replacement is disabled for non-plain action chords to preserve raw device actions."
            return
        }
        let validation = model.validateQuickDeviceChordInput(inputText, replacing: replacement)
        guard validation.isValid else {
            localError = validation.errors.joined(separator: "\n")
            return
        }
        if outputMode == .actions, phraseActions.isEmpty {
            localError = "Output actions are required."
            return
        }

        isCommitting = true
        let succeeded: Bool
        switch outputMode {
        case .plain:
            succeeded = await model.quickCommitDeviceUpsert(
                input: inputText,
                output: outputText,
                replacing: replacement
            )
        case .actions:
            succeeded = await model.quickCommitDeviceActionUpsert(
                input: inputText,
                phraseActions: phraseActions,
                replacing: replacement
            )
        }
        isCommitting = false
        if succeeded {
            onSuccess()
        } else {
            localError = model.lastError ?? "Quick commit failed."
        }
    }

    private var shouldAutoApplyAdvisorCandidate: Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inputSource == .advisor
    }

    private func applyAdvisorInput(_ value: String) {
        isApplyingAdvisorInput = true
        inputText = value
        DispatchQueue.main.async {
            self.isApplyingAdvisorInput = false
        }
    }
}

struct QuickChordAddView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: QuickChordAddController
    var showsCancel = true
    var contentPadding: CGFloat = 14
    var focusToken = 0
    var initialFocus: QuickChordEditorInitialFocus = .output
    let onCancel: () -> Void
    let onCommitSuccess: () -> Void

    @FocusState private var focusedField: FocusField?

    private enum FocusField: Hashable {
        case input
        case output
    }

    private var validation: ChordInputValidation {
        controller.validation(in: model)
    }

    private var inputTokens: [String] {
        validation.tokens
    }

    private var replacementChord: ChordEntry? {
        controller.replacementChord(in: model)
    }

    private var word: String {
        controller.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Chords that already type this word, so you don't add a second one
    /// by accident.
    private var existingChords: [ChordEntry] {
        guard !word.isEmpty, controller.outputMode == .plain else { return [] }
        let target = word.lowercased()
        return controller.quickChords(in: model).filter { chord in
            chord.id != controller.editingChord?.id
                && (chord.plainOutput ?? chord.output).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
        }
    }

    /// The keys you entered already type exactly this word.
    private var isDuplicate: Bool {
        guard let replacementChord, controller.editingChord == nil, controller.outputMode == .plain else { return false }
        return (replacementChord.plainOutput ?? replacementChord.output)
            .trimmingCharacters(in: .whitespacesAndNewlines) == word
    }

    private var isLocked: Bool {
        controller.editingChord.map { !AppModel.isQuickEditablePlainDeviceChord($0) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            wordSection
            if controller.editingChord == nil, controller.outputMode == .plain, word.count >= 2 {
                suggestionsSection
            }
            keysSection
            messages
            HStack(spacing: 8) {
                Spacer()
                if showsCancel {
                    Button("Cancel") {
                        controller.reset()
                        onCancel()
                    }
                }
                Button {
                    Task { await save() }
                } label: {
                    if controller.isCommitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(isDuplicate ? "Already added" : controller.activeReclaim != nil ? "Move & Add" : saveTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isSaveDisabled(in: model) || isDuplicate)
            }
        }
        .padding(contentPadding)
        .onAppear {
            scheduleInitialFocus()
            if !word.isEmpty, controller.quickCandidates.isEmpty {
                controller.scheduleQuickAdvisor(model: model, immediate: true)
            }
        }
        .onDisappear {
            controller.cancelTasks()
        }
        .onChange(of: focusToken) { _ in
            scheduleInitialFocus()
        }
        .onChange(of: controller.outputText) { _ in
            controller.outputTextChanged(model: model)
        }
        .onChange(of: controller.outputMode) { newValue in
            controller.outputModeChanged(newValue, model: model)
        }
        .onChange(of: controller.inputText) { newValue in
            controller.inputTextChanged(newValue)
        }
        .alert("Couldn't save the chord", isPresented: Binding(
            get: { controller.localError != nil },
            set: { newValue in
                if !newValue {
                    controller.localError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                controller.localError = nil
            }
        } message: {
            Text(controller.localError ?? "")
        }
    }

    private var saveTitle: String {
        switch controller.saveButtonTitle(in: model) {
        case "Add": return "Add to M4G"
        default: return controller.saveButtonTitle(in: model)
        }
    }

    // MARK: Word

    private var wordSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel(controller.outputMode == .plain ? "Word" : "Key actions")
                Spacer()
                Button(controller.outputMode == .plain ? "Use key actions instead" : "Use plain text instead") {
                    controller.outputMode = controller.outputMode == .plain ? .actions : .plain
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(isLocked)
                .help("Key actions type shortcuts, arrows and other keys instead of text")
            }
            switch controller.outputMode {
            case .plain:
                TextField("The word or phrase the chord types", text: $controller.outputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($focusedField, equals: .output)
                    .onSubmit {
                        Task { await save() }
                    }
            case .actions:
                MacroPhraseEditor(
                    actions: $controller.phraseActions,
                    actionText: $controller.phraseActionText
                )
            }
            wordContext
        }
    }

    @ViewBuilder
    private var wordContext: some View {
        let uses = model.shorthandWordUsage[word.lowercased()] ?? 0
        if !existingChords.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(existingChords.count == 1 ? "Already on your M4G:" : "Already on your M4G \(existingChords.count)×:")
                ForEach(existingChords.prefix(2)) { chord in
                    ActionTokenRow(tokens: chord.displayInput.map(ChordInputValidator.displayToken), tint: .green)
                        .fixedSize()
                }
                if uses > 0 {
                    Text("· written \(uses.formatted())× in 90 days")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        } else if uses > 0 {
            Label("You wrote this \(uses.formatted())× in the last 90 days", systemImage: "chart.bar.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Suggestions

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                sectionLabel("Suggested keys")
                if controller.isAdvisorLoading {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                if controller.quickCandidates.count > 1 {
                    Text("↑↓ to choose")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = controller.quickAdvisorError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if controller.quickCandidates.isEmpty && !controller.isAdvisorLoading {
                Text("No free keys found. Enter your own below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(controller.quickCandidates.prefix(4).enumerated()), id: \.element.id) { index, candidate in
                    Button {
                        controller.applyQuickCandidate(candidate)
                    } label: {
                        QuickAdvisorCandidateRow(
                            candidate: candidate,
                            rank: index,
                            isSelected: candidate.id == controller.selectedQuickCandidateID
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Keys

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Keys")
            HStack(spacing: 8) {
                TextField("e.g. b+t+w", text: $controller.inputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($focusedField, equals: .input)
                Button {
                    controller.captureActive.toggle()
                    if controller.captureActive {
                        focusedField = nil
                    }
                } label: {
                    Label(controller.captureActive ? "Recording" : "Record", systemImage: controller.captureActive ? "record.circle.fill" : "record.circle")
                        .foregroundStyle(controller.captureActive ? .red : .primary)
                }
                .help("Press keys to fill in the chord. Press Record again to stop.")
            }
            HStack(spacing: 8) {
                if inputTokens.isEmpty {
                    Text(controller.captureActive ? "Press the keys of the chord…" : "Pick a suggestion or type keys joined by +")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ActionTokenRow(tokens: inputTokens.map(ChordInputValidator.displayToken))
                        .fixedSize()
                    laptopNote
                }
            }
            .frame(minHeight: 22, alignment: .leading)
        }
    }

    /// Whether these keys can also be pressed together on a laptop.
    @ViewBuilder
    private var laptopNote: some View {
        let letters = inputTokens.compactMap { $0.count == 1 ? $0.lowercased().first : nil }
        if letters.count == inputTokens.count, letters.count >= 2 {
            if LaptopErgonomics.isComfortable(letters) {
                Label("Also easy on a laptop", systemImage: "laptopcomputer")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .help("These keys sit on different fingers of a laptop keyboard, so you can press them together there too.")
            } else {
                Label("On a laptop: type \(String(letters)) then Space", systemImage: "laptopcomputer")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Two of these keys share a finger on a laptop keyboard, so Chordsmith will give you other keys to press there.")
            }
        }
    }

    // MARK: Messages

    @ViewBuilder
    private var messages: some View {
        if let active = controller.activeReclaim {
            Label(
                "“\(active.reclaim.output)” moves to \(active.reclaim.movedKeys.joined(separator: "+")) so this word can have these keys. Nothing is deleted.",
                systemImage: "arrow.left.arrow.right"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let replacementChord, controller.editingChord == nil {
            let current = (replacementChord.plainOutput ?? replacementChord.output).trimmingCharacters(in: .whitespacesAndNewlines)
            Group {
                if isDuplicate {
                    Label("These keys already type “\(current)”.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else if controller.outputMode == .actions || AppModel.isQuickEditablePlainDeviceChord(replacementChord) {
                    Label("These keys type “\(current)” today. Saving changes them to “\(word)”.", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                } else {
                    Label("These keys run a macro. Switch to key actions to replace it.", systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
        }
        if !validation.errors.isEmpty, !controller.inputText.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(validation.errors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.red)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func save() async {
        guard !isDuplicate else { return }
        await controller.quickSave(model: model, onSuccess: onCommitSuccess)
    }

    private func scheduleFocus(_ field: FocusField) {
        focusedField = nil
        DispatchQueue.main.async {
            focusedField = field
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            focusedField = field
        }
    }

    private func scheduleInitialFocus() {
        if let editingChord = controller.editingChord,
           AppModel.isQuickEditablePlainDeviceChord(editingChord) {
            scheduleFocus(.output)
            return
        }

        switch initialFocus {
        case .input:
            scheduleFocus(.input)
        case .output:
            scheduleFocus(word.isEmpty ? .output : .input)
        }
    }
}

/// One row in the quick panel's list.
private enum QuickRow: Identifiable {
    case chord(ChordEntry)
    case worthAChord(GrowthItem)
    case addNew(String)

    var id: String {
        switch self {
        case .chord(let chord): return chord.id.uuidString
        case .worthAChord(let item): return "grow:\(item.word)"
        case .addNew(let word): return "add:\(word)"
        }
    }
}

struct QuickChordPanelView: View {
    @ObservedObject var model: AppModel
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var mode: Mode = .search
    @State private var selectedIndex = 0
    @StateObject private var addController = QuickChordAddController()
    @State private var addFocusToken = 0
    @State private var saved: (title: String, detail: String)?

    init(model: AppModel, initialQuery: String = "", onDismiss: @escaping () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
        _searchText = State(initialValue: initialQuery)
    }
    @FocusState private var focusedField: FocusField?

    private enum Mode {
        case search
        case add
    }

    private enum FocusField: Hashable {
        case search
    }

    private var quickChords: [ChordEntry] {
        model.chords.filter { chord in
            chord.profile == .cc2A1
                && (chord.deploymentTarget == .device || chord.deploymentTarget == .both)
        }
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rows: [QuickRow] {
        guard !query.isEmpty else {
            return model.growthPlan.items.prefix(6).map(QuickRow.worthAChord)
        }
        let chords = ChordSearch.ranked(quickChords, query: query, limit: 12)
        var rows = chords.map(QuickRow.chord)
        let exact = chords.contains { ($0.plainOutput ?? $0.output).trimmingCharacters(in: .whitespaces).lowercased() == query.lowercased() }
        if !exact {
            rows.append(.addNew(query))
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let saved {
                savedContent(saved)
            } else if mode == .search {
                searchContent
            } else {
                addContent
            }

            Divider()
            footer
        }
        .frame(width: 460)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .background(LocalShortcutMonitor { event in
            handleShortcut(event)
        })
        .onAppear {
            scheduleFocus(.search)
        }
        .onChange(of: searchText) { _ in
            selectedIndex = 0
        }
        .onDisappear {
            addController.cancelTasks()
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            if mode == .add {
                Button {
                    backToSearch()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to search (Esc)")
            } else {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
            }
            Text(mode == .search ? "Chords" : addController.editingChord == nil ? "New chord" : "Edit chord")
                .font(.headline)
            Spacer()
            if mode == .search {
                Button {
                    startAdd(prefilledOutput: query)
                } label: {
                    Label("New", systemImage: "plus")
                }
                .controlSize(.small)
                .help("Add a chord (⌘N)")
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if saved != nil {
                Spacer()
            } else if mode == .search {
                shortcut("↑↓", "select")
                shortcut("↩", query.isEmpty ? "add" : "open")
                shortcut("⌘N", "new")
                shortcut("⌘C", "copy")
                Spacer()
                shortcut("esc", query.isEmpty ? "close" : "clear")
            } else {
                shortcut("↩", "save")
                shortcut("⇥", "next field")
                if !addController.quickCandidates.isEmpty {
                    shortcut("↑↓", "suggestion")
                }
                Spacer()
                shortcut("esc", "back")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private func shortcut(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
    }

    // MARK: Search

    private var searchContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find a chord by word or keys", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focusedField, equals: .search)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if query.isEmpty {
                HStack {
                    Text(rows.isEmpty ? "" : "Worth a chord: you type these by hand most")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }

            if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("Type a word to find its chord, or press ⌘N to add one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                rowView(row, isSelected: index == selectedIndex)
                                    .id(row.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedIndex = index
                                        activate(row)
                                    }
                                    .onHover { hovering in
                                        if hovering { selectedIndex = index }
                                    }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selectedIndex) { _ in
                        scroll(using: proxy)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: QuickRow, isSelected: Bool) -> some View {
        switch row {
        case .chord(let chord):
            QuickChordResultRow(
                chord: chord,
                isSelected: isSelected,
                onCopy: { copyOutput(chord) },
                onEdit: { startEdit(chord) },
                onToggleStar: { Task { await model.toggleChordStarred(chord) } }
            )
        case .worthAChord(let item):
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(StatsPalette.library)
                Text(item.word)
                    .font(.body.weight(.medium))
                Text("\(item.frequency.formatted())× by hand")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let keys = item.candidates.first?.inputKeys {
                    ActionTokenRow(tokens: keys.map(ChordInputValidator.displayToken), tint: .secondary)
                        .fixedSize()
                }
            }
            .quickRowStyle(isSelected: isSelected)
        case .addNew(let word):
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Add a chord for “\(word)”")
                    .font(.body.weight(.medium))
                Spacer()
            }
            .quickRowStyle(isSelected: isSelected)
        }
    }

    // MARK: Add

    private var addContent: some View {
        QuickChordAddView(
            model: model,
            controller: addController,
            showsCancel: false,
            contentPadding: 14,
            focusToken: addFocusToken,
            initialFocus: .output,
            onCancel: backToSearch,
            onCommitSuccess: showSaved
        )
    }

    private func savedContent(_ saved: (title: String, detail: String)) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            Text(saved.title)
                .font(.headline)
            Text(saved.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }

    /// Confirms what was written and where, then closes.
    private func showSaved() {
        let word = addController.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = ChordInputValidator.tokens(from: addController.inputText, compactRepeatsUseDup: true)
            .map(ChordInputValidator.displayToken)
            .joined(separator: " + ")
        let title = word.isEmpty ? "Saved" : "\(word)  ←  \(keys)"
        let status = model.statusText.lowercased().contains("queued")
            ? "Saved here. The M4G wasn't reachable, so it's queued and will sync when it's connected."
            : "Written to your Master Forge."
        withAnimation(.easeOut(duration: 0.15)) {
            saved = (title, status)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            onDismiss()
        }
    }

    // MARK: Keys

    private func handleShortcut(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        if saved != nil { return false }

        if event.keyCode == 53 {
            if mode == .add {
                if addController.captureActive {
                    addController.captureActive = false
                } else {
                    backToSearch()
                }
            } else if !searchText.isEmpty {
                searchText = ""
            } else {
                onDismiss()
            }
            return true
        }

        if mode == .add, addController.handleCapture(event) {
            addFocusToken += 1
            return true
        }

        if command, event.charactersIgnoringModifiers?.lowercased() == "n" {
            startAdd(prefilledOutput: mode == .search ? query : "")
            return true
        }
        if command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            backToSearch()
            return true
        }

        if mode == .search {
            if command, event.charactersIgnoringModifiers?.lowercased() == "c" {
                if case .chord(let chord) = selectedRow {
                    copyOutput(chord)
                    return true
                }
                return false
            }
            if event.keyCode == 48, !command {
                startAdd(prefilledOutput: query)
                return true
            }
            if event.keyCode == 36 {
                if let selectedRow {
                    activate(selectedRow)
                } else {
                    startAdd(prefilledOutput: query)
                }
                return true
            }
            if event.keyCode == 125 {
                selectedIndex = min(selectedIndex + 1, max(rows.count - 1, 0))
                return true
            }
            if event.keyCode == 126 {
                selectedIndex = max(selectedIndex - 1, 0)
                return true
            }
        } else {
            if event.keyCode == 125, !addController.quickCandidates.isEmpty {
                addController.cycleQuickCandidate(delta: 1)
                return true
            }
            if event.keyCode == 126, !addController.quickCandidates.isEmpty {
                addController.cycleQuickCandidate(delta: -1)
                return true
            }
            if event.keyCode == 36 {
                Task {
                    await addController.quickSave(model: model, onSuccess: showSaved)
                }
                return true
            }
        }

        return false
    }

    private var selectedRow: QuickRow? {
        let rows = rows
        guard !rows.isEmpty else { return nil }
        return rows[min(selectedIndex, rows.count - 1)]
    }

    private func activate(_ row: QuickRow) {
        switch row {
        case .chord(let chord): startEdit(chord)
        case .worthAChord(let item): startAdd(prefilledOutput: item.word)
        case .addNew(let word): startAdd(prefilledOutput: word)
        }
    }

    private func scroll(using proxy: ScrollViewProxy) {
        guard let selectedRow else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(selectedRow.id, anchor: .center)
            }
        }
    }

    private func backToSearch() {
        addController.reset()
        mode = .search
        scheduleFocus(.search)
    }

    private func startAdd(prefilledInput: String = "", prefilledOutput: String = "") {
        addController.startAdd(prefilledInput: prefilledInput, prefilledOutput: prefilledOutput, model: model)
        mode = .add
        addFocusToken += 1
    }

    private func startEdit(_ chord: ChordEntry) {
        addController.startEdit(chord)
        mode = .add
        addFocusToken += 1
    }

    private func scheduleFocus(_ field: FocusField) {
        focusedField = nil
        DispatchQueue.main.async {
            focusedField = field
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            focusedField = field
        }
    }

    private func copyOutput(_ chord: ChordEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chord.plainOutput ?? chord.output, forType: .string)
        model.statusText = "Copied “\(chord.plainOutput ?? chord.output)”"
    }
}

private extension View {
    func quickRowStyle(isSelected: Bool) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
    }
}

private struct QuickChordResultRow: View {
    let chord: ChordEntry
    let isSelected: Bool
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onToggleStar: () -> Void

    private var inputTokens: [String] {
        (chord.displayInput.isEmpty ? chord.inputKeys : chord.displayInput)
            .map(ChordInputValidator.displayToken)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(chord.plainOutput ?? chord.output)
                .font(.body.weight(.medium))
                .lineLimit(1)
            if !AppModel.isQuickEditablePlainDeviceChord(chord) {
                Image(systemName: "command")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Macro or key actions")
            }
            if chord.isStarred {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
            Spacer(minLength: 8)
            ActionTokenRow(tokens: inputTokens)
                .fixedSize()
            if isSelected {
                HStack(spacing: 2) {
                    iconButton(chord.isStarred ? "star.slash" : "star", help: chord.isStarred ? "Unstar" : "Star", action: onToggleStar)
                    iconButton("doc.on.doc", help: "Copy the output (⌘C)", action: onCopy)
                    iconButton("pencil", help: "Edit (↩)", action: onEdit)
                }
            }
        }
        .quickRowStyle(isSelected: isSelected)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct QuickAdvisorCandidateRow: View {
    let candidate: Candidate
    let rank: Int
    let isSelected: Bool

    private var letters: [Character] {
        candidate.inputKeys.compactMap { $0.count == 1 ? $0.lowercased().first : nil }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .font(.caption)
            ActionTokenRow(tokens: candidate.inputKeys.map(ChordInputValidator.displayToken))
                .fixedSize()
            if rank == 0 {
                PanelBadge(text: "Best", tint: .green)
            }
            if let reclaim = candidate.reclaim {
                PanelBadge(text: "from “\(reclaim.output)”", tint: .secondary)
                    .help(candidate.softReasons.first ?? "")
            }
            Text(candidate.reclaim.map { reclaim in
                reclaim.uses == 0
                    ? "never written in \(reclaim.historyDays) days; it moves to \(reclaim.movedKeys.joined(separator: "+"))"
                    : "written \(reclaim.uses)× in \(reclaim.historyDays) days; it moves to \(reclaim.movedKeys.joined(separator: "+"))"
            } ?? candidate.softReasons.first ?? "Free and easy to press")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if letters.count == candidate.inputKeys.count, LaptopErgonomics.isComfortable(letters) {
                Image(systemName: "laptopcomputer")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .help("Also easy to press together on a laptop")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06))
        )
    }
}

private struct MacroPhraseEditor: View {
    @Binding var actions: [Int]
    @Binding var actionText: String
    @State private var selectedIndex: Int?
    @State private var actionError: String?

    private let commonActions = [
        "PRESS_NEXT",
        "RELEASE_NEXT",
        "LEFT_SHIFT",
        "LEFT_CTRL",
        "LEFT_ALT",
        "LEFT_GUI",
        "RIGHT_SHIFT",
        "ENTER",
        "TAB",
        "BKSP",
        "ESC",
        "space",
        "JOIN",
        "NO_CONCATENATOR"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    if actions.isEmpty {
                        Text("No output actions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                            actionChip(action, index: index)
                        }
                    }
                }
                .frame(minHeight: 32, alignment: .leading)
            }

            HStack(spacing: 6) {
                TextField("u, PRESS_NEXT, LEFT_SHIFT, 0x201", text: $actionText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTypedActions)
                Button {
                    addTypedActions()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("Insert typed action")
                Menu {
                    ForEach(commonActions, id: \.self) { token in
                        Button(token) {
                            insertAction(ActionCatalog.code(for: token) ?? 0)
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .help("Insert common action")
                Button {
                    deleteSelectedOrLast()
                } label: {
                    Image(systemName: "delete.left")
                }
                .buttonStyle(.bordered)
                .disabled(actions.isEmpty)
                .help("Delete selected or last action")
            }

            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Button("Shift Text") {
                    convertTypedTextToShiftMacro()
                }
                .disabled(actionText.isEmpty)
                .help("Convert typed text to PRESS_NEXT/LEFT_SHIFT actions for uppercase letters")
                Button("Clear") {
                    actions.removeAll()
                    selectedIndex = nil
                }
                .disabled(actions.isEmpty)
                Spacer()
                Text("Click a chip to choose the insertion point.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func actionChip(_ action: Int, index: Int) -> some View {
        let token = ActionCatalog.token(for: action)
        return Text(token)
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(index == selectedIndex ? Color.accentColor.opacity(0.24) : Color.purple.opacity(0.16))
            )
            .foregroundStyle(index == selectedIndex ? Color.accentColor : Color.purple)
            .contentShape(Capsule())
            .onTapGesture {
                selectedIndex = index
            }
            .contextMenu {
                Button("Insert Before") {
                    selectedIndex = index - 1
                }
                Button("Delete") {
                    deleteAction(at: index)
                }
            }
    }

    private func addTypedActions() {
        let parsed = parseActions(actionText)
        guard !parsed.isEmpty else {
            actionError = "Unknown action token."
            return
        }
        for action in parsed {
            insertAction(action)
        }
        actionText = ""
        actionError = nil
    }

    private func parseActions(_ text: String) -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let tokens = trimmed
            .components(separatedBy: CharacterSet(charactersIn: "+, \t\n"))
            .map { token in
                token
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            }
            .filter { !$0.isEmpty }
        let actions = tokens.compactMap { ActionCatalog.code(for: $0) }
        return actions.count == tokens.count ? actions : []
    }

    private func insertAction(_ action: Int) {
        let insertionIndex = min((selectedIndex ?? actions.count - 1) + 1, actions.count)
        actions.insert(action, at: max(insertionIndex, 0))
        selectedIndex = max(insertionIndex, 0)
        actionError = nil
    }

    private func deleteSelectedOrLast() {
        guard !actions.isEmpty else { return }
        deleteAction(at: selectedIndex ?? actions.count - 1)
    }

    private func deleteAction(at index: Int) {
        guard actions.indices.contains(index) else { return }
        actions.remove(at: index)
        if actions.isEmpty {
            selectedIndex = nil
        } else {
            selectedIndex = min(index, actions.count - 1)
        }
    }

    private func convertTypedTextToShiftMacro() {
        let text = actionText
        guard !text.isEmpty else { return }
        var converted: [Int] = []
        var shiftHeld = false

        func releaseShiftIfNeeded() {
            if shiftHeld {
                converted.append(contentsOf: [524, 513])
                shiftHeld = false
            }
        }

        for scalar in text.unicodeScalars {
            let value = Int(scalar.value)
            if CharacterSet.uppercaseLetters.contains(scalar),
               let lowerScalar = UnicodeScalar(String(scalar).lowercased()) {
                if !shiftHeld {
                    converted.append(contentsOf: [523, 513])
                    shiftHeld = true
                }
                converted.append(Int(lowerScalar.value))
            } else if value <= 0x7F {
                releaseShiftIfNeeded()
                converted.append(value)
            }
        }
        releaseShiftIfNeeded()

        guard !converted.isEmpty else {
            actionError = "No supported text actions."
            return
        }
        for action in converted {
            insertAction(action)
        }
        actionText = ""
        actionError = nil
    }
}
