import AppKit
import Combine
import Engine
import Foundation
import Library
import OSLog

private let shorthandLogger = Logger(subsystem: "com.poweroftrue.chordsmith", category: "Shorthand")

/// Where laptop shorthand stands right now, for the panel and menu bar.
enum ShorthandStatus: Equatable {
    case off
    case needsPermission
    case pausedForForge
    case pausedInApp(String)
    case active
    case failed

    var title: String {
        switch self {
        case .off: return "Off"
        case .needsPermission: return "Needs Accessibility access"
        case .pausedForForge: return "Paused: Master Forge connected"
        case .pausedInApp(let name): return "Paused in \(name)"
        case .active: return "On"
        case .failed: return "Couldn't start"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "Turn it on to type your chords on the laptop keyboard."
        case .needsPermission:
            return "To replace the letters you type, macOS needs you to allow Chordsmith under Privacy & Security › Accessibility."
        case .pausedForForge:
            return "Your Master Forge has real chords, so shorthands wait until it's unplugged."
        case .pausedInApp:
            return "You paused shorthands in this app. Everywhere else they work as usual."
        case .active:
            return "Press a chord's keys together, or type its three letters then Space. Backspace straight after puts your letters back."
        case .failed:
            return "The keyboard hook couldn't start. Quit and reopen Chordsmith, or check Accessibility access."
        }
    }

    var systemImage: String {
        switch self {
        case .off: return "keyboard"
        case .needsPermission, .failed: return "exclamationmark.triangle.fill"
        case .pausedForForge, .pausedInApp: return "pause.circle.fill"
        case .active: return "checkmark.circle.fill"
        }
    }
}

@MainActor
extension AppModel {
    // MARK: Lifecycle

    func startShorthand() async {
        hasStartedShorthand = true
        shorthandEngine.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleShorthandEvent(event) }
        }
        forgeConnectionCancellable = inputObserver.$isM4GConnected
            .removeDuplicates()
            .sink { [weak self] connected in
                self?.shorthandEngine.setForgeConnected(connected)
                self?.refreshShorthandStatus()
            }
        observeFrontmostApp()
        shorthandEngine.update(settings: shorthandSettings)
        await rebuildShorthands()
        await loadShorthandStats()
        applyShorthandEngineState()
    }

    /// Starts or stops the keyboard hook to match the settings. With
    /// shorthand off, no hook is installed at all.
    func applyShorthandEngineState() {
        shorthandEngine.update(settings: shorthandSettings)
        if shorthandSettings.enabled {
            if !shorthandEngine.isRunning {
                if ShorthandEngine.hasPermission() {
                    shorthandEngine.start()
                } else {
                    shorthandLogger.notice("Shorthand waiting for Accessibility access")
                    promptForShorthandPermissionOnce()
                    waitForShorthandPermission()
                }
            }
        } else {
            shorthandEngine.stop()
        }
        refreshShorthandStatus()
    }

    func requestShorthandPermission() {
        _ = ShorthandEngine.hasPermission(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        waitForShorthandPermission()
    }

    /// macOS shows its own Accessibility prompt once; after that the Laptop
    /// tab has the button.
    private func promptForShorthandPermissionOnce() {
        let key = "shorthand.permission_prompted"
        let service = libraryService
        Task {
            guard (try? await service.stringSetting(forKey: key)) == nil else { return }
            try? await service.setSetting(key, value: "1")
            _ = ShorthandEngine.hasPermission(prompt: true)
        }
    }

    private func waitForShorthandPermission() {
        guard shorthandPermissionTask == nil else { return }
        shorthandPermissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if ShorthandEngine.hasPermission() {
                    self.shorthandPermissionTask = nil
                    self.applyShorthandEngineState()
                    return
                }
            }
        }
    }

    func refreshShorthandStatus() {
        let status: ShorthandStatus
        if !shorthandSettings.enabled {
            status = .off
        } else if !ShorthandEngine.hasPermission() {
            status = .needsPermission
        } else if !shorthandEngine.isRunning {
            status = .failed
        } else if shorthandSettings.onlyWhenForgeUnplugged && inputObserver.isM4GConnected {
            status = .pausedForForge
        } else if let app = lastExternalApp, shorthandSettings.excludedBundleIDs.contains(app.bundleID) {
            status = .pausedInApp(app.name)
        } else {
            status = .active
        }
        if status != shorthandStatus { shorthandStatus = status }
    }

    private func observeFrontmostApp() {
        guard shorthandObservers.isEmpty else { return }
        let ownBundleID = Bundle.main.bundleIdentifier
        func remember(_ app: NSRunningApplication?) {
            guard let app, let bundleID = app.bundleIdentifier, bundleID != ownBundleID else { return }
            lastExternalApp = (bundleID, app.localizedName ?? bundleID)
        }
        remember(NSWorkspace.shared.frontmostApplication)
        shorthandObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                if let app, let bundleID = app.bundleIdentifier, bundleID != ownBundleID {
                    self.lastExternalApp = (bundleID, app.localizedName ?? bundleID)
                }
                self.refreshShorthandStatus()
            }
        })
    }

    // MARK: Events

    private func handleShorthandEvent(_ event: ShorthandEvent) {
        inputObserver.noteShorthand(event)
        let service = libraryService
        switch event.kind {
        case .edit:
            break
        case .expand, .chord:
            shorthandToday.expansions += 1
            shorthandToday.savedKeystrokes += event.savedKeystrokes
            shorthandPeriod.expansions += 1
            shorthandPeriod.savedKeystrokes += event.savedKeystrokes
            Task { try? await service.recordShorthandExpansion(savedKeystrokes: event.savedKeystrokes, at: event.at) }
        case .undo:
            shorthandToday.undos += 1
            shorthandPeriod.undos += 1
            let typed = event.typed
            Task {
                let blocked = (try? await service.recordShorthandUndo(token: typed, at: event.at)) ?? false
                if blocked {
                    self.statusText = "“\(typed)” will stay as typed from now on"
                    await self.reloadShorthandMatcher()
                }
            }
        }
    }

    // MARK: Catalog

    /// Converts the device chords into shorthands. The dictionary load and
    /// conversion run off the main thread.
    func rebuildShorthands() async {
        isRebuildingShorthands = true
        defer { isRebuildingShorthands = false }
        let service = libraryService
        let chords = deviceChordsForShorthand
        let usage = (try? await service.wordFrequencies(days: 90)) ?? [:]
        let realWords = (try? await service.shorthandRealWords(for: chords)) ?? ShorthandLetters.commonTokens
        shorthandRealWords = realWords
        let overrides = (try? await service.shorthandOverrides()) ?? [:]
        shorthandOverrides = overrides
        let catalog = await Task.detached(priority: .userInitiated) {
            ShorthandBuilder.build(chords: chords, realWords: realWords, overrides: overrides, usage: usage)
        }.value
        shorthandCatalog = catalog
        shorthandsByWord = catalog.byWord
        shorthandLogger.notice("Shorthand catalog: \(catalog.shorthands.count, privacy: .public) ready from \(chords.count, privacy: .public) chords")
        await reloadShorthandMatcher()
        shorthandWordUsage = usage
    }

    /// Picks up blocked and always-replaced tokens without rebuilding.
    func reloadShorthandMatcher() async {
        let states = (try? await libraryService.shorthandTokenStates()) ?? []
        shorthandTokenStates = states
        let matcher = ShorthandMatcher(
            catalog: shorthandCatalog,
            realWords: shorthandRealWords ?? ShorthandLetters.commonTokens,
            blocked: Set(states.filter { $0.state == "blocked" }.map(\.token)),
            allowed: Set(states.filter { $0.state == "allowed" }.map(\.token))
        )
        shorthandMatcher = matcher
        shorthandEngine.update(matcher: matcher)
        refreshShorthandStatus()
    }

    func loadShorthandStats() async {
        if let stats = try? await libraryService.shorthandStats(days: 30) {
            shorthandToday = stats.today
            shorthandPeriod = stats.period
        }
    }

    // MARK: Editing

    /// Checks letters you want for a chord. Returns a problem to show, or nil.
    func shorthandLettersProblem(_ letters: String, for chordID: UUID) -> String? {
        let cleaned = letters.lowercased().filter(ShorthandLetters.isShorthandCharacter)
        guard cleaned.count == letters.count else { return "Use letters, digits and ' only." }
        guard cleaned.count >= 3 else { return "Use at least three letters: two go off by accident." }
        if let other = shorthandCatalog.byToken[cleaned], other.chordID != chordID {
            return "These letters already give “\(other.output)”."
        }
        if shorthandMatcher.isRealWord(cleaned) {
            return "“\(cleaned)” is a word you type, so it would never be replaced. Try another order."
        }
        return nil
    }

    func setShorthandLetters(_ letters: String?, for chordID: UUID) async {
        do {
            try await libraryService.setShorthandOverride(chordID: chordID, letters: letters, disabled: false)
            await rebuildShorthands()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setShorthandDisabled(_ disabled: Bool, for chordID: UUID) async {
        do {
            let letters = shorthandOverrides[chordID]?.letters
            try await libraryService.setShorthandOverride(chordID: chordID, letters: letters, disabled: disabled)
            await rebuildShorthands()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// "blocked", "allowed" or nil to forget the token.
    func setShorthandToken(_ token: String, state: String?) async {
        do {
            try await libraryService.setShorthandTokenState(token, state: state)
            await reloadShorthandMatcher()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Settings

    func toggleShorthandPause(forBundleID bundleID: String) {
        if shorthandSettings.excludedBundleIDs.contains(bundleID) {
            shorthandSettings.excludedBundleIDs.remove(bundleID)
        } else {
            shorthandSettings.excludedBundleIDs.insert(bundleID)
        }
        Task { await saveShorthandSettings() }
    }

    func saveShorthandSettings() async {
        let keys = ShorthandSettings.storageKeys
        let settings = shorthandSettings
        do {
            try await libraryService.setSetting(keys.enabled, value: settings.enabled ? "1" : "0")
            try await libraryService.setSetting(keys.onlyWhenForgeUnplugged, value: settings.onlyWhenForgeUnplugged ? "1" : "0")
            try await libraryService.setSetting(keys.expandOnPunctuation, value: settings.expandOnPunctuation ? "1" : "0")
            try await libraryService.setSetting(keys.undoWithBackspace, value: settings.undoWithBackspace ? "1" : "0")
            try await libraryService.setSetting(keys.mashChords, value: settings.mashChords ? "1" : "0")
            try await libraryService.setSetting(keys.excludedBundleIDs, value: settings.excludedBundleIDs.sorted().joined(separator: ","))
        } catch {
            lastError = error.localizedDescription
        }
        if hasStartedShorthand { applyShorthandEngineState() }
    }

    func loadShorthandSettings() async {
        let keys = ShorthandSettings.storageKeys
        func flag(_ key: String, default value: Bool) async -> Bool {
            guard let stored = try? await libraryService.stringSetting(forKey: key) else { return value }
            return stored == "1"
        }
        var settings = ShorthandSettings()
        settings.enabled = await flag(keys.enabled, default: true)
        settings.onlyWhenForgeUnplugged = await flag(keys.onlyWhenForgeUnplugged, default: true)
        settings.expandOnPunctuation = await flag(keys.expandOnPunctuation, default: true)
        settings.undoWithBackspace = await flag(keys.undoWithBackspace, default: true)
        settings.mashChords = await flag(keys.mashChords, default: true)
        // Carry over apps excluded from the old software chording engine.
        let stored = try? await libraryService.stringSetting(forKey: keys.excludedBundleIDs)
        let legacy = try? await libraryService.stringSetting(forKey: "engine.excluded_bundle_ids")
        settings.excludedBundleIDs = Set(
            (stored ?? legacy ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        shorthandSettings = settings
    }
}
