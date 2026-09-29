import Library
import SwiftUI

/// Your chords as laptop shorthands: status, what you saved, and every
/// shorthand with the letters to type.
struct LaptopTabView: View {
    @ObservedObject var model: AppModel
    @State private var filter: Filter = .ready
    @State private var search = ""
    @State private var editing: LaptopShorthand?

    enum Filter: String, CaseIterable, Identifiable {
        case ready = "Type"
        case invented = "Press"
        case notNeeded = "Not needed"
        case blocked = "Off & blocked"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusCard
            metrics
            HStack(spacing: 8) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField("Search word or letters", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 170)
            }
            content
        }
        .popover(item: $editing, arrowEdge: .trailing) { shorthand in
            ShorthandEditor(model: model, shorthand: shorthand) { editing = nil }
        }
    }

    // MARK: Status

    private var statusCard: some View {
        let status = model.shorthandStatus
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.systemImage)
                .font(.title3)
                .foregroundStyle(statusTint(status))
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Laptop shorthand · \(status.title)")
                    .font(.headline)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                statusActions(status)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Toggle("On", isOn: $model.shorthandSettings.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Turn laptop shorthand on or off")
                .onChange(of: model.shorthandSettings.enabled) { _ in
                    Task { await model.saveShorthandSettings() }
                }
        }
        .padding(10)
        .background(statusTint(status).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func statusActions(_ status: ShorthandStatus) -> some View {
        switch status {
        case .needsPermission, .failed:
            Button("Allow in Accessibility Settings…") { model.requestShorthandPermission() }
                .controlSize(.small)
        case .pausedForForge:
            Button("Use shorthands with the Forge connected too") {
                model.shorthandSettings.onlyWhenForgeUnplugged = false
                Task { await model.saveShorthandSettings() }
            }
            .controlSize(.small)
        case .pausedInApp:
            if let app = model.lastExternalApp {
                Button("Resume in \(app.name)") { model.toggleShorthandPause(forBundleID: app.bundleID) }
                    .controlSize(.small)
            }
        case .active:
            HStack(spacing: 10) {
                ExampleKeys(letters: model.shorthandCatalog.shorthands.first { $0.word == "about" }?.letters ?? "abt",
                            output: model.shorthandCatalog.shorthands.first { $0.word == "about" }?.output ?? "about")
                if let app = model.lastExternalApp {
                    Button("Pause in \(app.name)") { model.toggleShorthandPause(forBundleID: app.bundleID) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        case .off:
            EmptyView()
        }
    }

    private func statusTint(_ status: ShorthandStatus) -> Color {
        switch status {
        case .active: return .green
        case .needsPermission, .failed: return .orange
        case .pausedForForge, .pausedInApp, .off: return .secondary
        }
    }

    // MARK: Metrics

    private var metrics: some View {
        let ready = model.shorthandCatalog.shorthands.count
        return HStack(spacing: 8) {
            PanelMetric(title: "Ready", value: ready.formatted(), detail: "of \(model.deviceChordsForShorthand.count.formatted()) chords")
            PanelMetric(title: "Today", value: model.shorthandToday.expansions.formatted(), detail: "\(model.shorthandToday.savedKeystrokes.formatted()) keys saved")
            PanelMetric(title: "Last 30 days", value: model.shorthandPeriod.expansions.formatted(), detail: "\(model.shorthandPeriod.savedKeystrokes.formatted()) keys saved")
            PanelMetric(title: "Undone", value: model.shorthandPeriod.undos.formatted(), detail: "backspace right after")
        }
    }

    // MARK: Lists

    @ViewBuilder
    private var content: some View {
        switch filter {
        case .ready:
            shorthandList(readyItems, empty: model.deviceChordsForShorthand.isEmpty
                ? "Sync your Master Forge chords first, then they show up here as shorthands."
                : "No shorthand matches your search.")
        case .invented:
            shorthandList(inventedItems, empty: "No short words to press together.")
        case .notNeeded:
            notNeededList
        case .blocked:
            blockedList
        }
    }

    private var readyItems: [LaptopShorthand] {
        sorted(model.shorthandCatalog.shorthands.filter { $0.kind != .pressTogether && matchesSearch($0.output, $0.letters) })
    }

    private var inventedItems: [LaptopShorthand] {
        sorted(model.shorthandCatalog.shorthands.filter { $0.kind == .pressTogether && matchesSearch($0.output, $0.pressKeys ?? $0.letters) })
    }

    /// Most-written words first: those are the shorthands worth learning.
    private func sorted(_ items: [LaptopShorthand]) -> [LaptopShorthand] {
        let usage = model.shorthandWordUsage
        return items.sorted { lhs, rhs in
            let left = usage[lhs.word] ?? 0, right = usage[rhs.word] ?? 0
            if left != right { return left > right }
            if lhs.savedKeystrokes != rhs.savedKeystrokes { return lhs.savedKeystrokes > rhs.savedKeystrokes }
            return lhs.output < rhs.output
        }
    }

    private func matchesSearch(_ output: String, _ letters: String = "") -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return output.lowercased().contains(query) || letters.contains(query)
    }

    private func shorthandList(_ items: [LaptopShorthand], empty: String) -> some View {
        Group {
            if items.isEmpty {
                PanelEmptyState(icon: "keyboard", title: "Nothing here", detail: empty)
            } else {
                List(items) { shorthand in
                    ShorthandRow(
                        shorthand: shorthand,
                        uses: model.shorthandWordUsage[shorthand.word] ?? 0,
                        onEdit: { editing = shorthand },
                        onDisable: { Task { await model.setShorthandDisabled(true, for: shorthand.chordID) } },
                        onReset: shorthand.kind == .custom
                            ? { Task { await model.setShorthandLetters(nil, for: shorthand.chordID) } }
                            : nil
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    private var notNeededList: some View {
        let reasons: [ShorthandSkipReason] = [.typeTheWord, .noSavings, .awkwardOnLaptop, .notText, .conflict]
        let items = model.shorthandCatalog.skipped.filter { reasons.contains($0.reason) && matchesSearch($0.output) }
        return List {
            ForEach(reasons, id: \.self) { reason in
                let group = items.filter { $0.reason == reason }
                if !group.isEmpty {
                    Section("\(reason.displayName) (\(group.count))") {
                        ForEach(group.prefix(200)) { item in
                            HStack {
                                Text(item.output).lineLimit(1)
                                Spacer()
                                ActionTokenRow(tokens: item.chordKeys, tint: .secondary).fixedSize()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var blockedList: some View {
        let disabled = model.shorthandCatalog.skipped.filter { $0.reason == .disabled && matchesSearch($0.output) }
        let blocked = model.shorthandTokenStates.filter { $0.state == "blocked" && matchesSearch($0.token) }
        let allowed = model.shorthandTokenStates.filter { $0.state == "allowed" && matchesSearch($0.token) }
        return Group {
            if disabled.isEmpty && blocked.isEmpty && allowed.isEmpty {
                PanelEmptyState(
                    icon: "hand.raised",
                    title: "Nothing blocked",
                    detail: "Undo a replacement twice with Backspace and those letters stay as typed from then on. They show up here so you can change your mind."
                )
            } else {
                List {
                    if !blocked.isEmpty {
                        Section("Stay as typed (you undid them)") {
                            ForEach(blocked, id: \.token) { state in
                                HStack {
                                    Text(state.token).font(.system(.body, design: .monospaced))
                                    Spacer()
                                    Button("Replace again") { Task { await model.setShorthandToken(state.token, state: nil) } }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    if !allowed.isEmpty {
                        Section("Always replaced, even though they're words") {
                            ForEach(allowed, id: \.token) { state in
                                HStack {
                                    Text(state.token).font(.system(.body, design: .monospaced))
                                    Spacer()
                                    Button("Stop") { Task { await model.setShorthandToken(state.token, state: nil) } }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    if !disabled.isEmpty {
                        Section("Turned off") {
                            ForEach(disabled) { item in
                                HStack {
                                    Text(item.output)
                                    Spacer()
                                    Button("Turn on") { Task { await model.setShorthandDisabled(false, for: item.chordID) } }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

// MARK: - Rows

struct ShorthandRow: View {
    let shorthand: LaptopShorthand
    let uses: Int
    let onEdit: () -> Void
    let onDisable: () -> Void
    let onReset: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(shorthand.output)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if shorthand.kind == .custom {
                        PanelBadge(text: shorthand.kind.displayName, tint: badgeTint)
                    }
                }
                HStack(spacing: 4) {
                    Text("M4G")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ActionTokenRow(tokens: shorthand.chordKeys, tint: .secondary)
                        .fixedSize()
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if shorthand.kind == .pressTogether {
                    LetterKeys(letters: shorthand.pressKeys ?? shorthand.letters, together: true)
                } else {
                    LetterKeys(letters: shorthand.letters)
                    if let keys = shorthand.pressKeys {
                        HStack(spacing: 4) {
                            Text(shorthand.pressAdjusted ? "or press (laptop keys)" : "or press")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            LetterKeys(letters: keys, together: true)
                        }
                        .help(shorthand.pressAdjusted
                            ? "Three keys on three fingers that no word you type starts with, so typing fast never sets them off. J or K joins in when the word's own letters aren't safe."
                            : "Press these keys at the same moment.")
                    }
                }
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Menu {
                Button("Change letters…", action: onEdit)
                if let onReset {
                    Button("Use the chord's own letters", action: onReset)
                }
                Divider()
                Button("Turn off", action: onDisable)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options for \(shorthand.output)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(shorthand.kind == .pressTogether
            ? "\(shorthand.output): press \((shorthand.pressKeys ?? shorthand.letters).map(String.init).joined(separator: " ")) together"
            : "\(shorthand.output): type \(shorthand.letters.map(String.init).joined(separator: " ")), then space")
    }

    private var detail: String {
        var parts = ["saves \(shorthand.savedKeystrokes)"]
        if uses > 0 { parts.append("\(uses.formatted())× in 90 days") }
        return parts.joined(separator: " · ")
    }

    private var badgeTint: Color {
        switch shorthand.kind {
        case .custom: return .purple
        case .newShortcut: return .orange
        case .doubledLetter: return .teal
        case .sameKeys: return .blue
        case .pressTogether: return .indigo
        }
    }
}

/// The letters to type, as key caps, with the Space that triggers them,
/// or joined with + when they are pressed together.
struct LetterKeys: View {
    let letters: String
    var together = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                if together && index > 0 {
                    Text("+").font(.caption2).foregroundStyle(.secondary)
                }
                KeyCap(text: String(letter))
            }
            if !together {
                KeyCap(text: "space", wide: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(together ? "\(letters), pressed together" : "\(letters), then space")
    }
}

private struct KeyCap: View {
    let text: String
    var wide = false

    var body: some View {
        Text(text)
            .font(.system(size: wide ? 9 : 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(wide ? .secondary : .primary)
            .frame(minWidth: wide ? 34 : 17, minHeight: 17)
            .padding(.horizontal, wide ? 2 : 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
    }
}

private struct ExampleKeys: View {
    let letters: String
    let output: String

    var body: some View {
        HStack(spacing: 5) {
            LetterKeys(letters: letters)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(output)
                .font(.caption.weight(.semibold))
        }
    }
}

// MARK: - Editor

private struct ShorthandEditor: View {
    @ObservedObject var model: AppModel
    let shorthand: LaptopShorthand
    let onClose: () -> Void
    @State private var letters = ""

    private var problem: String? {
        letters.isEmpty ? nil : model.shorthandLettersProblem(letters, for: shorthand.chordID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Letters for “\(shorthand.output)”")
                .font(.headline)
            Text("Type these letters in this order, then Space. Use at least three, and pick ones that aren't a word you'd type on their own.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(shorthand.letters, text: $letters)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(save)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !letters.isEmpty {
                LetterKeys(letters: letters.lowercased())
            }
            HStack {
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(letters.isEmpty || problem != nil)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { letters = shorthand.letters }
    }

    private func save() {
        guard !letters.isEmpty, problem == nil else { return }
        let chosen = letters.lowercased()
        let chordID = shorthand.chordID
        onClose()
        Task { await model.setShorthandLetters(chosen, for: chordID) }
    }
}
