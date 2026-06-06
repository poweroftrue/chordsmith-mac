@preconcurrency import AppKit
import Library
import SwiftUI

struct QuickChordPanelView: View {
    @ObservedObject var model: AppModel
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var mode: Mode = .search
    @State private var selectedIndex = 0
    @State private var editingChord: ChordEntry?
    @State private var inputText = ""
    @State private var outputText = ""
    @State private var outputMode: OutputMode = .plain
    @State private var phraseActions: [Int] = []
    @State private var phraseActionText = ""
    @State private var captureActive = false
    @State private var isCommitting = false
    @State private var localError: String?
    @State private var pendingDelete: ChordEntry?
    @State private var showDeleteConfirmation = false
    @State private var quickCandidates: [Candidate] = []
    @State private var selectedQuickCandidateID: String?
    @State private var quickAdvisorTask: Task<Void, Never>?
    @State private var isAdvisorLoading = false
    @State private var quickAdvisorError: String?
    @State private var inputSource: InputSource = .empty
    @State private var isApplyingAdvisorInput = false
    @FocusState private var focusedField: FocusField?

    private enum Mode {
        case search
        case add
    }

    private enum OutputMode: String, CaseIterable, Identifiable {
        case plain = "Plain"
        case actions = "Actions"

        var id: String { rawValue }
    }

    private enum FocusField: Hashable {
        case search
        case input
        case output
    }

    private enum InputSource {
        case empty
        case advisor
        case manual
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

    private var baseValidation: ChordInputValidation {
        model.validateQuickDeviceChordInput(inputText, replacing: editingChord)
    }

    private var replacementChord: ChordEntry? {
        guard editingChord == nil,
              let conflictID = baseValidation.conflictingChordID else {
            return nil
        }
        return quickChords.first { $0.id == conflictID }
    }

    private var validation: ChordInputValidation {
        if let replacementChord, outputMode == .actions || AppModel.isQuickEditablePlainDeviceChord(replacementChord) {
            return model.validateQuickDeviceChordInput(inputText, replacing: replacementChord)
        }
        return baseValidation
    }

    private var inputTokens: [String] {
        validation.tokens
    }

    private var saveButtonTitle: String {
        if editingChord != nil {
            return "Save"
        }
        if replacementChord != nil {
            return "Replace"
        }
        return "Add"
    }

    private var isSaveDisabled: Bool {
        if isCommitting || !validation.isValid {
            return true
        }
        switch outputMode {
        case .plain:
            return outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .actions:
            return phraseActions.isEmpty
        }
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
        .onChange(of: outputText) { _ in
            guard mode == .add, outputMode == .plain else { return }
            scheduleQuickAdvisor()
        }
        .onChange(of: outputMode) { newValue in
            if newValue == .actions {
                if phraseActions.isEmpty, !outputText.isEmpty {
                    phraseActions = ActionCodec.phraseActions(forPlainText: outputText)
                }
                clearQuickAdvisor()
            } else if mode == .add {
                if outputText.isEmpty, let plainText = ActionCatalog.plainText(for: phraseActions) {
                    outputText = plainText
                }
                scheduleQuickAdvisor()
            }
        }
        .onChange(of: inputText) { newValue in
            guard mode == .add, !isApplyingAdvisorInput else { return }
            inputSource = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .manual
        }
        .onDisappear {
            quickAdvisorTask?.cancel()
        }
        .alert("Delete Chord?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    Task { await quickDelete(pendingDelete) }
                }
            }
        } message: {
            if let pendingDelete {
                Text("Delete \(pendingDelete.normalizedInput) -> \(pendingDelete.output)?")
            }
        }
        .alert("Quick Chord", isPresented: Binding(
            get: { localError != nil },
            set: { newValue in
                if !newValue {
                    localError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                localError = nil
            }
        } message: {
            Text(localError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: mode == .search ? "magnifyingglass" : "plus.circle.fill")
                .foregroundStyle(.blue)
                .font(.title3)
            Text(mode == .search ? "Quick Chords" : editingChord == nil ? "Quick Add" : "Quick Edit")
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Input")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("i+dup", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .input)
                    Button {
                        captureActive.toggle()
                        if captureActive {
                            focusedField = nil
                        }
                    } label: {
                        Image(systemName: captureActive ? "keyboard.badge.eye.fill" : "keyboard.badge.eye")
                    }
                    .buttonStyle(.bordered)
                    .help("Capture OS-visible keys")
                }
                tokenPreview
            }

            quickAdvisorContent

            outputEditor

            if let replacementChord, editingChord == nil {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(outputMode == .actions || AppModel.isQuickEditablePlainDeviceChord(replacementChord)
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
                Button("Cancel") {
                    resetAdd()
                    mode = .search
                    scheduleFocus(.search)
                }
                Button {
                    Task { await quickSave() }
                } label: {
                    if isCommitting {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Text(saveButtonTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaveDisabled)
            }
        }
        .padding(14)
    }

    private var outputEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Output Mode", selection: $outputMode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .disabled(editingChord.map { !AppModel.isQuickEditablePlainDeviceChord($0) } ?? false)
            }

            switch outputMode {
            case .plain:
                TextField("Expanded text", text: $outputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .output)
                    .onSubmit {
                        Task { await quickSave() }
                    }
            case .actions:
                MacroPhraseEditor(
                    actions: $phraseActions,
                    actionText: $phraseActionText
                )
            }
        }
    }

    private var tokenPreview: some View {
        HStack {
            if captureActive {
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
        if editingChord == nil, outputMode == .plain {
            VStack(alignment: .leading, spacing: 6) {
                if isAdvisorLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finding M4G suggestions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 24, alignment: .leading)
                } else if let quickAdvisorError {
                    Label(quickAdvisorError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(minHeight: 24, alignment: .leading)
                } else if !quickCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Suggestions")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(quickCandidates.prefix(5)) { candidate in
                            Button {
                                applyQuickCandidate(candidate)
                            } label: {
                                QuickAdvisorCandidateRow(
                                    candidate: candidate,
                                    isSelected: candidate.id == selectedQuickCandidateID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
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

        if captureActive,
           mode == .add,
           event.keyCode != 36,
           event.keyCode != 48,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            if let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty {
                var tokens = ChordInputValidator.tokens(from: inputText, compactRepeatsUseDup: true)
                for char in chars where char.isLetter || char.isNumber {
                    let token = String(char)
                    tokens.append(tokens.contains(token) ? "dup" : token)
                }
                inputText = tokens.joined(separator: "+")
                selectedQuickCandidateID = nil
                inputSource = inputText.isEmpty ? .empty : .manual
                return true
            }
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
            if event.keyCode == 125, !quickCandidates.isEmpty {
                cycleQuickCandidate(delta: 1)
                return true
            }
            if event.keyCode == 126, !quickCandidates.isEmpty {
                cycleQuickCandidate(delta: -1)
                return true
            }
            if event.keyCode == 36 {
                Task { await quickSave() }
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
            resetAdd()
            mode = .search
            scheduleFocus(.search)
        }
    }

    private func scheduleQuickAdvisor(immediate: Bool = false) {
        quickAdvisorTask?.cancel()
        quickAdvisorError = nil

        guard mode == .add, editingChord == nil, outputMode == .plain else {
            clearQuickAdvisor()
            return
        }

        let word = outputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
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

    private func clearQuickAdvisor(clearAdvisorInput: Bool = false) {
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

    private var shouldAutoApplyAdvisorCandidate: Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inputSource == .advisor
    }

    private func applyQuickCandidate(_ candidate: Candidate, shouldFocusInput: Bool = true) {
        selectedQuickCandidateID = candidate.id
        guard shouldAutoApplyAdvisorCandidate || shouldFocusInput else { return }
        applyAdvisorInput(candidate.inputKeys.joined(separator: "+"))
        inputSource = .advisor
        captureActive = false
        if shouldFocusInput {
            scheduleFocus(.input)
        }
    }

    private func applyAdvisorInput(_ value: String) {
        isApplyingAdvisorInput = true
        inputText = value
        DispatchQueue.main.async {
            isApplyingAdvisorInput = false
        }
    }

    private func cycleQuickCandidate(delta: Int) {
        guard !quickCandidates.isEmpty else { return }
        let currentIndex = selectedQuickCandidateID.flatMap { selectedID in
            quickCandidates.firstIndex { $0.id == selectedID }
        } ?? 0
        let nextIndex = (currentIndex + delta + quickCandidates.count) % quickCandidates.count
        applyQuickCandidate(quickCandidates[nextIndex])
    }

    private func startAdd(prefilledInput: String = "", prefilledOutput: String = "") {
        resetAdd()
        mode = .add
        inputText = prefilledInput
        outputText = prefilledOutput
        outputMode = .plain
        inputSource = prefilledInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .manual
        scheduleQuickAdvisor(immediate: true)
        scheduleFocus(.input)
    }

    private func startEdit(_ chord: ChordEntry) {
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
        mode = .add
        scheduleFocus(AppModel.isQuickEditablePlainDeviceChord(chord) ? .output : .input)
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

    private func resetAdd() {
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

    private func copyOutput(_ chord: ChordEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chord.plainOutput ?? chord.output, forType: .string)
    }

    private func confirmDelete(_ chord: ChordEntry) {
        pendingDelete = chord
        showDeleteConfirmation = true
    }

    private func quickSave() async {
        guard !isCommitting else { return }
        let replacement = editingChord ?? replacementChord
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
            onDismiss()
        } else {
            localError = model.lastError ?? "Quick commit failed."
        }
    }

    private func quickDelete(_ chord: ChordEntry) async {
        guard !isCommitting else { return }
        isCommitting = true
        let succeeded = await model.quickCommitDeviceDelete(chord)
        isCommitting = false
        pendingDelete = nil
        if succeeded {
            onDismiss()
        } else {
            localError = model.lastError ?? "Quick delete failed."
        }
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
