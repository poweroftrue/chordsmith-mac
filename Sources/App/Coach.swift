import AppKit
import Engine
import Library
import SwiftUI

// MARK: - Nudge decisions

struct Nudge: Identifiable, Equatable {
    enum Kind: Equatable {
        /// You typed a word letter by letter that you have a chord for.
        case forgotten
        /// You misspelled a word you have a chord for.
        case typo(intended: String)
        /// You keep typing a word with no chord; here is one.
        case suggestion(candidate: [String])
        /// On the laptop: the word has a shorthand.
        case shorthand(letters: String)
    }

    let id = UUID()
    let kind: Kind
    let word: String
    let input: [String]
    let detail: String

    var title: String {
        if case .typo(let intended) = kind {
            return "\(word) → \(intended)"
        }
        return word
    }
}

struct CoachSettings: Equatable {
    var enabled = true
    var forgotten = true
    var typos = true
    var suggestions = true
    /// Only coach while typing on the Master Forge.
    var m4gOnly = false
    var maxPerHour = 12

    static let storageKeys = (
        enabled: "coach.enabled",
        forgotten: "coach.forgotten",
        typos: "coach.typos",
        suggestions: "coach.suggestions",
        m4gOnly: "coach.m4g_only",
        maxPerHour: "coach.max_per_hour"
    )
}

/// Decides when a nudge is worth interrupting for. Feedback right after the
/// moment works best, but only if it stays rare enough not to be tuned out.
struct CoachEngine {
    static let minimumGap: TimeInterval = 20
    static let wordCooldown: TimeInterval = 10 * 60
    static let suggestionThreshold = 3

    private(set) var lastShownAt: Date?
    private(set) var shownAt: [Date] = []
    private var wordShownAt: [String: Date] = [:]
    private var suggestedToday: Set<String> = []
    private var suggestionDay: Date?

    mutating func nudge(
        for event: RecordedWord,
        handCountToday: Int,
        snapshot: CoachingSnapshot,
        suggestions: [String: [String]],
        settings: CoachSettings,
        shorthands: [String: LaptopShorthand] = [:],
        shorthandActive: Bool = false,
        now: Date = .now
    ) -> Nudge? {
        guard settings.enabled, event.word.count >= 2 else { return nil }

        // Without the Forge, the only faster way is the laptop shorthand.
        if event.source == .keyboardAway {
            guard settings.forgotten, shorthandActive,
                  let shorthand = shorthands[event.word], shorthand.savedKeystrokes >= 2 else { return nil }
            let nudge = Nudge(
                kind: .shorthand(letters: shorthand.letters),
                word: event.word,
                input: shorthand.letters.map { String($0) } + ["space"],
                detail: handCountToday > 1
                    ? "Typed in full \(handCountToday)× today. Type \(shorthand.letters) then Space"
                    : "Type \(shorthand.letters) then Space, any letter order"
            )
            guard isAllowed(word: nudge.word, settings: settings, now: now) else { return nil }
            record(nudge, now: now)
            return nudge
        }

        guard event.source == .keyboard || event.source == .m4gTyping,
              !(settings.m4gOnly && event.source != .m4gTyping) else { return nil }

        let candidate: Nudge?
        if settings.forgotten, let input = snapshot.chordInputs[event.word] {
            candidate = Nudge(
                kind: .forgotten,
                word: event.word,
                input: input,
                detail: handCountToday > 1 ? "Typed by hand \(handCountToday)× today" : "You have a chord for this"
            )
        } else if settings.typos, let intended = snapshot.typoTargets[event.word], let input = snapshot.chordInputs[intended] {
            candidate = Nudge(
                kind: .typo(intended: intended),
                word: event.word,
                input: input,
                detail: "A chord never misspells \(intended)"
            )
        } else if settings.suggestions,
                  handCountToday >= Self.suggestionThreshold,
                  let input = suggestions[event.word] {
            resetSuggestionsIfNewDay(now)
            guard !suggestedToday.contains(event.word) else { return nil }
            candidate = Nudge(
                kind: .suggestion(candidate: input),
                word: event.word,
                input: input,
                detail: "Typed by hand \(handCountToday)× today. Add this chord to your M4G?"
            )
        } else {
            candidate = nil
        }

        guard let nudge = candidate, isAllowed(word: nudge.word, settings: settings, now: now) else { return nil }
        record(nudge, now: now)
        return nudge
    }

    private func isAllowed(word: String, settings: CoachSettings, now: Date) -> Bool {
        if let lastShownAt, now.timeIntervalSince(lastShownAt) < Self.minimumGap { return false }
        if let last = wordShownAt[word], now.timeIntervalSince(last) < Self.wordCooldown { return false }
        let lastHour = shownAt.filter { now.timeIntervalSince($0) < 3_600 }
        return lastHour.count < max(settings.maxPerHour, 1)
    }

    private mutating func record(_ nudge: Nudge, now: Date) {
        lastShownAt = now
        wordShownAt[nudge.word] = now
        shownAt = shownAt.filter { now.timeIntervalSince($0) < 3_600 } + [now]
        if case .suggestion = nudge.kind {
            suggestedToday.insert(nudge.word)
        }
    }

    private mutating func resetSuggestionsIfNewDay(_ now: Date) {
        if let suggestionDay, Calendar.current.isDate(suggestionDay, inSameDayAs: now) { return }
        suggestionDay = now
        suggestedToday = []
    }
}

// MARK: - Nudge panel

/// A small floating card under the menu bar. It never takes focus, so typing
/// continues uninterrupted, and it fades out on its own.
@MainActor
final class NudgePanelController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var isHovering = false
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func show(_ nudge: Nudge) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let view = NudgeView(
            nudge: nudge,
            onAdd: { [weak self] in self?.add(nudge) },
            onSkipForever: { [weak self] in self?.skip(nudge) },
            onClose: { [weak self] in self?.dismiss() },
            onHover: { [weak self] hovering in
                self?.isHovering = hovering
                if !hovering { self?.scheduleDismiss(after: 2) }
            }
        )
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        position(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
        NSAccessibility.post(element: hosting, notification: .announcementRequested, userInfo: [
            .announcement: announcement(for: nudge),
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
        if case .suggestion = nudge.kind {
            scheduleDismiss(after: 9)
        } else {
            scheduleDismiss(after: 4.5)
        }
    }

    private func announcement(for nudge: Nudge) -> String {
        if case .shorthand(let letters) = nudge.kind {
            return "\(nudge.title). Type \(letters) then space."
        }
        return "\(nudge.title). Chord \(nudge.input.joined(separator: " plus "))."
    }

    func dismiss() {
        dismissTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.isHovering else { return }
                self.dismiss()
            }
        }
    }

    private func add(_ nudge: Nudge) {
        guard case .suggestion(let input) = nudge.kind, let model else { return }
        dismiss()
        Task {
            _ = await model.quickCommitDeviceUpsert(input: input.joined(separator: "+"), output: nudge.word)
        }
    }

    private func skip(_ nudge: Nudge) {
        guard let model else { return }
        dismiss()
        Task { await model.skipGrowthWord(named: nudge.word) }
    }

    private func makePanel() -> NSPanel {
        let panel = NudgePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 14, y: frame.maxY - size.height - 10))
    }
}

private final class NudgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons in a panel that never becomes key must react to the first click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NudgeView: View {
    let nudge: Nudge
    let onAdd: () -> Void
    let onSkipForever: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(nudge.title)
                        .font(.headline)
                    ActionTokenRow(tokens: nudge.input).fixedSize()
                }
                Text(nudge.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .suggestion = nudge.kind {
                    HStack(spacing: 8) {
                        Button("Add chord", action: onAdd)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Not now", action: onClose)
                            .controlSize(.small)
                        Button("Never for this word", action: onSkipForever)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    .padding(.top, 2)
                }
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(12)
        .frame(width: 330, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .onHover(perform: onHover)
    }

    private var icon: String {
        switch nudge.kind {
        case .forgotten: return "keyboard.chevron.compact.down"
        case .typo: return "textformat.abc.dottedunderline"
        case .suggestion: return "sparkles"
        case .shorthand: return "laptopcomputer"
        }
    }

    private var tint: Color {
        switch nudge.kind {
        case .forgotten: return StatsPalette.chorded
        case .typo: return StatsPalette.typos
        case .suggestion: return StatsPalette.library
        case .shorthand: return StatsPalette.chorded
        }
    }
}
