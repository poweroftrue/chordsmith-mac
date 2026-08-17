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

    func quickSave(model: AppModel, onSuccess: @escaping () -> Void) async {
        guard !isCommitting else { return }
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
    var initialFocus: QuickChordEditorInitialFocus = .input
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Input")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("i+dup", text: $controller.inputText)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .input)
                    Button {
                        controller.captureActive.toggle()
                        if controller.captureActive {
                            focusedField = nil
                        }
                    } label: {
                        Image(systemName: controller.captureActive ? "keyboard.badge.eye.fill" : "keyboard.badge.eye")
                    }
                    .buttonStyle(.bordered)
                    .help("Capture OS-visible keys")
                }
                tokenPreview
            }

            quickAdvisorContent

            outputEditor

            if let replacementChord, controller.editingChord == nil {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(controller.outputMode == .actions || AppModel.isQuickEditablePlainDeviceChord(replacementChord)
                         ? "Will replace \(replacementChord.output)"
                         : "Switch to Actions to replace this macro chord")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if !validation.errors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(validation.errors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.red)
            }

            HStack {
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
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Text(controller.saveButtonTitle(in: model))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isSaveDisabled(in: model))
            }
        }
        .padding(contentPadding)
        .onAppear {
            scheduleInitialFocus()
            if !controller.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        .alert("Quick Chord", isPresented: Binding(
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

    private var outputEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Output Mode", selection: $controller.outputMode) {
                    ForEach(QuickChordOutputMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .disabled(controller.editingChord.map { !AppModel.isQuickEditablePlainDeviceChord($0) } ?? false)
            }

            switch controller.outputMode {
            case .plain:
                TextField("Expanded text", text: $controller.outputText)
                    .textFieldStyle(.roundedBorder)
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
        }
    }

    private var tokenPreview: some View {
        HStack {
            if controller.captureActive {
                Label("Capturing", systemImage: "record.circle")
                    .foregroundStyle(.blue)
            }
            if inputTokens.isEmpty {
                Text("No input")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ActionTokenRow(tokens: inputTokens.map(ChordInputValidator.displayToken))
            }
        }
        .frame(minHeight: 26, alignment: .leading)
    }

    @ViewBuilder
    private var quickAdvisorContent: some View {
        if controller.editingChord == nil, controller.outputMode == .plain {
            VStack(alignment: .leading, spacing: 6) {
                if controller.isAdvisorLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finding M4G suggestions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 24, alignment: .leading)
                } else if let quickAdvisorError = controller.quickAdvisorError {
                    Label(quickAdvisorError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(minHeight: 24, alignment: .leading)
                } else if !controller.quickCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Suggestions")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(controller.quickCandidates.prefix(5)) { candidate in
                            Button {
                                controller.applyQuickCandidate(candidate)
                                scheduleFocus(.input)
                            } label: {
                                QuickAdvisorCandidateRow(
                                    candidate: candidate,
                                    isSelected: candidate.id == controller.selectedQuickCandidateID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func save() async {
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
            scheduleFocus(.output)
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

    private var filteredChords: [ChordEntry] {
        guard !searchText.isEmpty else { return [] }
        return ChordSearch.ranked(quickChords, query: searchText, limit: 12)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if mode == .search {
                searchContent
            } else {
                addContent
            }

            Divider()
            footer
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: mode == .search ? "magnifyingglass" : "plus.circle.fill")
                .foregroundStyle(.blue)
                .font(.title3)
            Text(mode == .search ? "Quick Chords" : addController.editingChord == nil ? "Quick Add" : "Quick Edit")
                .font(.headline)
            Spacer()
            Button {
                switchMode()
            } label: {
                Image(systemName: mode == .search ? "plus.circle" : "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(mode == .search ? "Add chord" : "Search chords")
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var searchContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search M4G chords", text: $searchText)
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
            .padding(14)

            if searchText.isEmpty {
                emptyState(icon: "keyboard", text: "Search, add, edit, or delete M4G chords")
            } else if filteredChords.isEmpty {
                VStack(spacing: 12) {
                    emptyState(icon: "magnifyingglass", text: "No matching M4G chord")
                    Button {
                        startAdd(prefilledOutput: searchText)
                    } label: {
                        Label("Add Chord", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.bottom, 18)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(filteredChords.enumerated()), id: \.element.id) { index, chord in
                                QuickChordResultRow(
                                    chord: chord,
                                    isSelected: index == selectedIndex,
                                    onCopy: { copyOutput(chord) },
                                    onEdit: { startEdit(chord) },
                                    onToggleStar: { Task { await model.toggleChordStarred(chord) } }
                                )
                                .id(chord.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedIndex = index
                                    startEdit(chord)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 290)
                    .onChange(of: selectedIndex) { _ in
                        scrollSelectedChord(using: proxy)
                    }
                    .onChange(of: filteredChords.map(\.id)) { _ in
                        selectedIndex = min(selectedIndex, max(filteredChords.count - 1, 0))
                        scrollSelectedChord(using: proxy)
                    }
                }
            }
        }
    }

    private var addContent: some View {
        QuickChordAddView(
            model: model,
            controller: addController,
            showsCancel: true,
            contentPadding: 14,
            focusToken: addFocusToken,
            onCancel: {
                addController.reset()
                mode = .search
                scheduleFocus(.search)
            },
            onCommitSuccess: {
                onDismiss()
            }
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            shortcut("Tab", mode == .search ? "add" : "search")
            shortcut("Return", mode == .search ? "edit" : "save")
            if mode == .search {
                shortcut("Cmd+C", "copy")
            }
            Spacer()
            shortcut("Esc", "close")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func shortcut(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            Text(label)
        }
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            onDismiss()
            return true
        }

        if mode == .add, addController.handleCapture(event) {
            addFocusToken += 1
            return true
        }

        if event.keyCode == 48 {
            switchMode()
            return true
        }

        if mode == .search {
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                if let chord = selectedChord {
                    copyOutput(chord)
                }
                return true
            }
            if event.keyCode == 36 {
                if let chord = selectedChord {
                    startEdit(chord)
                } else {
                    startAdd(prefilledOutput: searchText)
                }
                return true
            }
            if event.keyCode == 125 {
                selectedIndex = min(selectedIndex + 1, max(filteredChords.count - 1, 0))
                return true
            }
            if event.keyCode == 126 {
                selectedIndex = max(selectedIndex - 1, 0)
                return true
            }
        } else {
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
                Task {
                    await addController.quickSave(model: model) {
                        onDismiss()
                    }
                }
                return true
            }
        }

        return false
    }

    private var selectedChord: ChordEntry? {
        guard !filteredChords.isEmpty else { return nil }
        return filteredChords[min(selectedIndex, filteredChords.count - 1)]
    }

    private func scrollSelectedChord(using proxy: ScrollViewProxy) {
        guard let selectedChord else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(selectedChord.id, anchor: .center)
            }
        }
    }

    private func switchMode() {
        if mode == .search {
            startAdd(prefilledOutput: searchText)
        } else {
            addController.reset()
            mode = .search
            scheduleFocus(.search)
        }
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
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(chord.plainOutput ?? chord.output)
                        .font(.headline)
                        .lineLimit(1)
                    if !AppModel.isQuickEditablePlainDeviceChord(chord) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                ActionTokenRow(tokens: inputTokens)
                if !chord.actionFlags.isEmpty {
                    ActionTokenRow(tokens: chord.actionFlags.map(\.rawValue).sorted(), tint: .orange)
                }
                Text("\(chord.deploymentTarget.displayName) • \(chord.source)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onToggleStar()
            } label: {
                Image(systemName: chord.isStarred ? "star.fill" : "star")
                    .foregroundStyle(chord.isStarred ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(chord.isStarred ? "Unstar chord" : "Star chord")
            Button {
                onCopy()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy output")
            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }
}

private struct QuickAdvisorCandidateRow: View {
    let candidate: Candidate
    let isSelected: Bool

    private var reason: String {
        candidate.softReasons.first ?? "Valid M4G chord"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ActionTokenRow(tokens: candidate.inputKeys.map(ChordInputValidator.displayToken))
                .frame(maxWidth: 160, alignment: .leading)
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(candidate.score, format: .number.precision(.fractionLength(1)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
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
