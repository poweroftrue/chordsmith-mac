import AppKit
import Combine
import Device
import Engine
import Foundation
import Library

enum PanelTab: String, CaseIterable, Identifiable {
    case library
    case advisor
    case add
    case staged
    case suggestions
    case usage

    var id: String { rawValue }
}

struct StagedChordChange: Identifiable, Hashable {
    enum Kind: String {
        case upsert = "Add/Edit"
        case delete = "Delete"
    }

    let id = UUID()
    let kind: Kind
    let chord: ChordEntry

    var summary: String {
        "\(kind.rawValue) \(chord.normalizedInput) -> \(chord.output)"
    }
}

struct PendingDeviceMutation: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case upsert
        case delete
    }

    let id: UUID
    let kind: Kind
    let record: DeviceChordRecord

    init(id: UUID = UUID(), kind: Kind, record: DeviceChordRecord) {
        self.id = id
        self.kind = kind
        self.record = record
    }

    init(kind: Kind, chord: ChordEntry) {
        self.init(kind: kind, record: DeviceChordRecord(chord: chord))
    }

    var mutation: DeviceMutation {
        switch kind {
        case .upsert:
            return .upsert(record)
        case .delete:
            return .delete(record)
        }
    }

    var inputIdentity: String {
        if let rawInput = record.rawInput, rawInput.count == 32 {
            return "raw:\(rawInput.uppercased())"
        }
        if let rawInputActions = record.rawInputActions {
            return "raw:\(ActionCodec.stringifyChordActions(rawInputActions))"
        }
        return "text:\(ChordEntry.normalizeInputKeys(record.inputKeys))"
    }
}

protocol AppDeviceService: Sendable {
    func preferredPrimarySnapshot(progress: ((Int, Int) -> Void)?) throws -> (DeviceSource, [DeviceChordRecord])?
    func snapshot(path: String, expectedCount: Int?, progress: ((Int, Int) -> Void)?) throws -> [DeviceChordRecord]
    func applyMutations(_ mutations: [DeviceMutation], to path: String) throws
}

extension CharaChorderDeviceService: AppDeviceService {}

@MainActor
final class AppModel: ObservableObject {
    @Published var chords: [ChordEntry] = []
    @Published var suggestions: [Suggestion] = []
    @Published var advisorExistingChords: [ChordEntry] = []
    @Published var advisorCandidates: [Candidate] = []
    @Published var advisorRejectedCandidates: [Candidate] = []
    @Published var stagedChanges: [StagedChordChange] = []
    @Published var pendingDeviceMutations: [PendingDeviceMutation] = []
    @Published var selectedTab: PanelTab = .library
    @Published var deviceSource: DeviceSource?
    @Published var statusText = "Starting…"
    @Published var bootstrapProgress: (current: Int, total: Int)?
    @Published var lastError: String?
    @Published var engineEnabled = true
    @Published var inputObservationEnabled = true
    @Published var activeSoftwareProfile: ErgonomicProfile = .ansiQwerty
    @Published var excludedBundleIDsText = ""
    @Published var suggestionProfile: ErgonomicProfile = .ansiQwerty
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var canManageLaunchAtLogin = false
    @Published private(set) var launchAtLoginStatusText = "Checking launch-at-login status…"
    @Published var usageOverview = UsageOverview(
        wordsToday: 0,
        chordsToday: 0,
        words7Days: 0,
        chords7Days: 0,
        words30Days: 0,
        chords30Days: 0,
        wordsAllTime: 0,
        chordsAllTime: 0
    )
    @Published var recentWordUsage: [DailyWordUsage] = []
    @Published var recentChordUsage: [DailyChordUsage] = []
    @Published var twoKeyChordImpact: [TwoKeyChordImpact] = []
    @Published var wordCoverageReport = WordCoverageReport.empty
    @Published var usageLanguageFilter: WordLanguage? = nil
    @Published var usageCoverageDays: Int? = 30

    let libraryService: LibraryService
    let deviceService: any AppDeviceService
    let recorder: TypingRecorder
    let engine: ChordEngine
    let inputObserver: InputObservationEngine
    private let launchAtLoginController: LaunchAtLoginController
    private static let pendingDeviceMutationsSettingKey = "device.pending_mutations.v1"
    private static let launchAtLoginAttemptedSettingKey = "startup.launch_at_login_attempted.v1"

    convenience init() throws {
        let libraryService = try LibraryService()
        self.init(libraryService: libraryService, deviceService: CharaChorderDeviceService())
    }

    init(libraryService: LibraryService, deviceService: any AppDeviceService) {
        self.libraryService = libraryService
        self.deviceService = deviceService
        self.recorder = TypingRecorder(libraryService: libraryService)
        self.engine = ChordEngine(recorder: recorder)
        self.inputObserver = InputObservationEngine(recorder: recorder)
        self.launchAtLoginController = LaunchAtLoginController()
    }

    func start() {
        Task {
            await loadSettings()
            await configureLaunchAtLogin()
            await loadPendingDeviceMutations()
            await bootstrapIfNeeded()
            do {
                _ = try await libraryService.migrateLegacyTimingInferencesIfNeeded()
            } catch {
                lastError = error.localizedDescription
                statusText = "Could not clean legacy usage data"
            }
            await refresh()
            engine.start()
            if inputObservationEnabled {
                inputObserver.start()
            }
            statusText = "Ready"
        }
    }

    func stop() {
        engine.stop()
        inputObserver.stop()
    }

    func refresh() async {
        do {
            chords = try await libraryService.allChords()
            suggestions = try await libraryService.listSuggestions(profile: suggestionProfile)
            let activeChords = try await libraryService.activeChords(for: activeSoftwareProfile)
            let deviceChords = try await libraryService.deviceChords()
            engine.updateChords(activeChords)
            await recorder.updateDeviceChords(deviceChords)
            engine.updateConfiguration(
                EngineConfiguration(
                    enabled: engineEnabled,
                    activeProfile: activeSoftwareProfile,
                    excludedBundleIDs: parsedExcludedBundleIDs()
                )
            )
            deviceSource = try await libraryService.sources().first(where: { $0.isPrimary })
            await loadUsageReport()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func bootstrapIfNeeded() async {
        do {
            if try await libraryService.isBootstrapped() {
                deviceSource = try await libraryService.sources().first(where: { $0.isPrimary })
                statusText = "Loaded existing library"
                return
            }

            statusText = "Importing primary device…"
            guard let (source, snapshot) = try deviceService.preferredPrimarySnapshot(progress: { [weak self] current, total in
                Task { @MainActor in
                    self?.bootstrapProgress = (current, total)
                    self?.statusText = "Importing device \(current)/\(total)"
                }
            }) else {
                statusText = "No device found for bootstrap"
                return
            }

            let nexusURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/CharaChorder/nexus/nexus_freqlog_db.sqlite3")
            let freechorderURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".config/freechorder/chords.yaml")

            try await libraryService.bootstrap(
                primarySource: source,
                deviceChords: snapshot,
                nexusPath: nexusURL,
                freechorderPath: freechorderURL
            )
            bootstrapProgress = nil
            statusText = "Imported primary device and local stats"
            deviceSource = source
        } catch {
            bootstrapProgress = nil
            lastError = error.localizedDescription
            statusText = "Bootstrap failed"
        }
    }

    func regenerateSuggestions() async {
        do {
            statusText = "Rebuilding suggestions…"
            suggestions = try await libraryService.regenerateSuggestions(profile: suggestionProfile)
            statusText = "Suggestions updated"
        } catch {
            lastError = error.localizedDescription
            statusText = "Suggestion rebuild failed"
        }
    }

    func loadUsageReport() async {
        do {
            usageOverview = try await libraryService.usageOverview()
            recentWordUsage = try await libraryService.dailyWordUsage(days: 30, limit: 50)
            recentChordUsage = try await libraryService.dailyChordUsage(days: 30, limit: 50)
            twoKeyChordImpact = try await libraryService.twoKeyChordImpactReport(limit: 100)
            wordCoverageReport = try await libraryService.wordCoverageReport(
                days: usageCoverageDays,
                language: usageLanguageFilter,
                limitPerGroup: 100
            )
        } catch {
            lastError = error.localizedDescription
            statusText = "Usage report failed"
        }
    }

    func toggleInputObservation() {
        if inputObserver.isRunning {
            inputObservationEnabled = false
            inputObserver.stop()
            statusText = "Usage recorder paused"
        } else {
            inputObservationEnabled = true
            inputObserver.start()
            statusText = inputObserver.isRunning ? "Usage recorder running" : "Usage recorder could not start"
        }
    }

    func resumeInputObservationIfNeeded() {
        guard inputObservationEnabled, !inputObserver.isRunning else { return }
        inputObserver.start()
    }

    func openInputMonitoringSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        applyLaunchAtLoginState(launchAtLoginController.setEnabled(enabled))
        Task {
            try? await libraryService.setSetting(
                Self.launchAtLoginAttemptedSettingKey,
                value: "1"
            )
        }
    }

    func refreshLaunchAtLoginStatus() {
        applyLaunchAtLoginState(launchAtLoginController.currentState())
    }

    func openLoginItemSettings() {
        launchAtLoginController.openLoginItemSettings()
    }

    func setUsageLanguageFilter(_ language: WordLanguage?) {
        usageLanguageFilter = language
        Task { await loadUsageReport() }
    }

    func setUsageCoverageDays(_ days: Int?) {
        usageCoverageDays = days
        Task { await loadUsageReport() }
    }

    func addChord(input: String, output: String, profile: ErgonomicProfile, deploymentTarget: DeploymentTarget, enabled: Bool = true, source: String = "user") async {
        let tokens: [String]
        if Self.isDeviceTarget(deploymentTarget) {
            let validation = ChordInputValidator.validateM4GDeviceInput(input, existingChords: chords)
            guard validation.isValid else {
                lastError = validation.errors.joined(separator: "\n")
                statusText = "Chord input rejected"
                return
            }
            tokens = validation.tokens
        } else {
            tokens = input
                .replacingOccurrences(of: "+", with: ",")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        }

        guard !tokens.isEmpty, !output.isEmpty else {
            lastError = "Both input and output are required."
            return
        }

        do {
            let chord = ChordEntry(
                inputKeys: tokens,
                output: output,
                profile: profile,
                deploymentTarget: deploymentTarget,
                source: source,
                enabled: enabled
            )
            stagedChanges.append(StagedChordChange(kind: .upsert, chord: chord))
            statusText = "Staged chord \(chord.normalizedInput) -> \(output)"
        }
    }

    func commitStagedChanges() async {
        guard !stagedChanges.isEmpty else { return }
        let changes = stagedChanges
        let shouldRefreshSuggestions = selectedTab == .suggestions &&
            (suggestionProfile == .cc2A1 || suggestionProfile == activeSoftwareProfile)
        _ = await commitChanges(
            changes,
            clearStagedChangesOnLocalCommit: true,
            refreshSuggestions: shouldRefreshSuggestions,
            startStatus: "Committing \(changes.count) staged changes...",
            localOnlyStatus: "Staged changes committed",
            syncingStatus: "Committed locally; syncing M4G...",
            syncedStatus: "Committed and synced to M4G",
            queuedStatus: "Committed locally; M4G sync failed and is queued",
            queueSaveFailedStatus: "Committed locally; M4G sync failed and queue save failed",
            failureStatus: "Commit failed"
        )
    }

    func validateQuickDeviceChordInput(_ input: String, replacing chord: ChordEntry? = nil) -> ChordInputValidation {
        ChordInputValidator.validateM4GDeviceInput(
            input,
            existingChords: chords,
            replacingChordID: chord?.id,
            compactRepeatsUseDup: true
        )
    }

    func quickCommitDeviceUpsert(input: String, output: String, replacing chord: ChordEntry? = nil) async -> Bool {
        let validation = validateQuickDeviceChordInput(input, replacing: chord)
        guard validation.isValid else {
            lastError = validation.errors.joined(separator: "\n")
            statusText = "Quick chord input rejected"
            return false
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Output is required."
            statusText = "Quick chord input rejected"
            return false
        }

        if let chord, !Self.isQuickEditablePlainDeviceChord(chord) {
            lastError = "Quick edit is disabled for non-plain action chords to preserve raw device actions."
            statusText = "Quick edit rejected"
            return false
        }

        let now = Date()
        let quickChord = ChordEntry(
            id: chord?.id ?? UUID(),
            inputKeys: validation.tokens,
            output: output,
            profile: .cc2A1,
            deploymentTarget: .device,
            source: chord?.source ?? "quick_add",
            enabled: true,
            createdAt: chord?.createdAt ?? now,
            updatedAt: now
        )
        let changes: [StagedChordChange]
        if let chord,
           let oldInputIdentity = Self.deviceInputIdentity(chord),
           oldInputIdentity != validation.encodedInput?.uppercased() {
            changes = [
                StagedChordChange(kind: .delete, chord: chord),
                StagedChordChange(kind: .upsert, chord: quickChord)
            ]
        } else {
            changes = [StagedChordChange(kind: .upsert, chord: quickChord)]
        }
        return await commitChanges(
            changes,
            clearStagedChangesOnLocalCommit: false,
            refreshSuggestions: false,
            startStatus: "Quick committing chord...",
            localOnlyStatus: "Quick chord committed",
            syncingStatus: "Quick chord committed locally; syncing M4G...",
            syncedStatus: "Quick chord committed and synced to M4G",
            queuedStatus: "Quick chord committed locally; M4G sync failed and is queued",
            queueSaveFailedStatus: "Quick chord committed locally; M4G sync failed and queue save failed",
            failureStatus: "Quick commit failed"
        )
    }

    func quickCommitDeviceActionUpsert(input: String, phraseActions: [Int], replacing chord: ChordEntry? = nil) async -> Bool {
        let validation = validateQuickDeviceChordInput(input, replacing: chord)
        guard validation.isValid, let inputActions = validation.rawInputActions else {
            lastError = validation.errors.joined(separator: "\n")
            statusText = "Quick chord input rejected"
            return false
        }
        guard !phraseActions.isEmpty else {
            lastError = "Output actions are required."
            statusText = "Quick chord action output rejected"
            return false
        }

        let raw = RawChordRecord(inputActions: inputActions, phraseActions: phraseActions)
        let now = Date()
        let quickChord = ChordEntry(
            id: chord?.id ?? UUID(),
            inputKeys: raw.display.inputTokens,
            output: raw.display.plainOutput ?? raw.display.displayOutput,
            rawInputActions: raw.inputActions,
            rawPhraseActions: raw.phraseActions,
            encodedInput: raw.encodedInput,
            encodedPhrase: raw.encodedPhrase,
            displayInput: raw.display.inputTokens,
            phraseTokens: raw.display.phraseTokens,
            actionFlags: raw.display.flags,
            plainOutput: raw.display.plainOutput,
            profile: .cc2A1,
            deploymentTarget: .device,
            source: chord?.source ?? "quick_add",
            enabled: true,
            createdAt: chord?.createdAt ?? now,
            updatedAt: now
        )

        let changes: [StagedChordChange]
        if let chord,
           let oldInputIdentity = Self.deviceInputIdentity(chord),
           oldInputIdentity != raw.encodedInput.uppercased() {
            changes = [
                StagedChordChange(kind: .delete, chord: chord),
                StagedChordChange(kind: .upsert, chord: quickChord)
            ]
        } else {
            changes = [StagedChordChange(kind: .upsert, chord: quickChord)]
        }

        return await commitChanges(
            changes,
            clearStagedChangesOnLocalCommit: false,
            refreshSuggestions: false,
            startStatus: "Quick committing action chord...",
            localOnlyStatus: "Quick action chord committed",
            syncingStatus: "Quick action chord committed locally; syncing M4G...",
            syncedStatus: "Quick action chord committed and synced to M4G",
            queuedStatus: "Quick action chord committed locally; M4G sync failed and is queued",
            queueSaveFailedStatus: "Quick action chord committed locally; M4G sync failed and queue save failed",
            failureStatus: "Quick action commit failed"
        )
    }

    func quickCommitDeviceDelete(_ chord: ChordEntry) async -> Bool {
        await commitChanges(
            [StagedChordChange(kind: .delete, chord: chord)],
            clearStagedChangesOnLocalCommit: false,
            refreshSuggestions: false,
            startStatus: "Quick deleting chord...",
            localOnlyStatus: "Quick chord deleted",
            syncingStatus: "Quick delete committed locally; syncing M4G...",
            syncedStatus: "Quick chord deleted and synced to M4G",
            queuedStatus: "Quick chord deleted locally; M4G sync failed and is queued",
            queueSaveFailedStatus: "Quick chord deleted locally; M4G sync failed and queue save failed",
            failureStatus: "Quick delete failed"
        )
    }

    private func commitChanges(
        _ changes: [StagedChordChange],
        clearStagedChangesOnLocalCommit: Bool,
        refreshSuggestions: Bool,
        startStatus: String,
        localOnlyStatus: String,
        syncingStatus: String,
        syncedStatus: String,
        queuedStatus: String,
        queueSaveFailedStatus: String,
        failureStatus: String
    ) async -> Bool {
        guard !changes.isEmpty else { return true }
        do {
            lastError = nil
            let hasDeviceChanges = changes.contains { change in
                change.chord.deploymentTarget == .device || change.chord.deploymentTarget == .both
            }
            let syncPortPath = deviceSource?.portPath
            var committedDeviceMutations: [PendingDeviceMutation] = []
            statusText = startStatus
            for change in changes {
                switch change.kind {
                case .upsert:
                    try await libraryService.upsertChord(change.chord)
                    if Self.isDeviceTarget(change.chord.deploymentTarget) {
                        committedDeviceMutations.append(PendingDeviceMutation(kind: .upsert, chord: change.chord))
                    }
                case .delete:
                    if Self.isDeviceTarget(change.chord.deploymentTarget) {
                        committedDeviceMutations.append(PendingDeviceMutation(kind: .delete, chord: change.chord))
                    }
                    try await libraryService.deleteChord(id: change.chord.id)
                }
            }
            if clearStagedChangesOnLocalCommit {
                stagedChanges.removeAll()
            }
            if refreshSuggestions {
                _ = try await libraryService.regenerateSuggestions(profile: suggestionProfile)
            }
            await refresh()
            guard hasDeviceChanges else {
                statusText = localOnlyStatus
                return true
            }

            do {
                statusText = syncingStatus
                try await applyDeviceMutations(committedDeviceMutations, portPath: syncPortPath)
                statusText = pendingDeviceMutations.isEmpty
                    ? syncedStatus
                    : "\(syncedStatus). \(pendingDeviceMutations.count) queued M4G change\(pendingDeviceMutations.count == 1 ? "" : "s") still need retry."
                return true
            } catch {
                pendingDeviceMutations = Self.coalescedPendingDeviceMutations(pendingDeviceMutations + committedDeviceMutations)
                let syncError = error.localizedDescription
                do {
                    try await savePendingDeviceMutations()
                    lastError = syncError
                    statusText = queuedStatus
                } catch {
                    lastError = "M4G sync failed: \(syncError). Queue save failed: \(error.localizedDescription)"
                    statusText = queueSaveFailedStatus
                }
                return true
            }
        } catch {
            lastError = error.localizedDescription
            statusText = failureStatus
            return false
        }
    }

    func undoLastStagedChange() {
        guard let removed = stagedChanges.popLast() else { return }
        statusText = "Removed staged change: \(removed.summary)"
    }

    func deleteChord(_ chord: ChordEntry) async {
        stagedChanges.append(StagedChordChange(kind: .delete, chord: chord))
        statusText = "Staged delete \(chord.normalizedInput)"
    }

    func toggleChordStarred(_ chord: ChordEntry) async {
        await setChordStarred(chord, starred: !chord.isStarred)
    }

    func setChordStarred(_ chord: ChordEntry, starred: Bool) async {
        do {
            try await libraryService.setChordStarred(id: chord.id, starred: starred)
            applyStarredState(chordID: chord.id, starred: starred)
            statusText = starred ? "Starred \(chord.output)" : "Unstarred \(chord.output)"
        } catch {
            lastError = error.localizedDescription
            statusText = "Chord feedback failed"
        }
    }

    func acceptSuggestion(_ suggestion: Suggestion, candidate: Candidate, target: DeploymentTarget) async {
        await addChord(
            input: candidate.inputKeys.joined(separator: ","),
            output: suggestion.word,
            profile: suggestion.profile,
            deploymentTarget: target,
            enabled: true,
            source: "suggestion"
        )
    }

    private func applyStarredState(chordID: UUID, starred: Bool) {
        chords = chords.map { $0.id == chordID ? $0.withStarred(starred) : $0 }
        advisorExistingChords = advisorExistingChords.map { $0.id == chordID ? $0.withStarred(starred) : $0 }
    }

    func adviseChord(for word: String) async {
        let requestedOutput = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWord = requestedOutput.lowercased()
        guard !normalizedWord.isEmpty else {
            advisorExistingChords = []
            advisorCandidates = []
            advisorRejectedCandidates = []
            statusText = "Enter a word"
            return
        }

        do {
            let existingChords = try await libraryService.deviceChords(forOutput: normalizedWord)
            let candidates = try await libraryService.adviseChord(
                for: requestedOutput,
                profile: .cc2A1,
                allowExistingOutput: true,
                limit: 10
            )
            let rejected = try await libraryService.diagnoseRejectedChordCandidates(
                for: requestedOutput,
                profile: .cc2A1,
                allowExistingOutput: true,
                limit: 8
            )
            advisorExistingChords = existingChords
            advisorCandidates = candidates
            advisorRejectedCandidates = rejected
            if !existingChords.isEmpty {
                let noun = existingChords.count == 1 ? "chord" : "chords"
                if candidates.isEmpty {
                    statusText = "\(requestedOutput) already has \(existingChords.count) M4G \(noun); no additional suggestions"
                } else {
                    let suggestionNoun = candidates.count == 1 ? "suggestion" : "suggestions"
                    statusText = "\(requestedOutput) already has \(existingChords.count) M4G \(noun); found \(candidates.count) more \(suggestionNoun)"
                }
            } else {
                statusText = candidates.isEmpty
                    ? "No conflict-free candidate found for \(requestedOutput)"
                    : "Advisor found \(candidates.count) candidates"
            }
        } catch {
            lastError = error.localizedDescription
            statusText = "Advisor failed"
        }
    }

    func quickAdvisorCandidates(for word: String, limit: Int = 5) async throws -> [Candidate] {
        let normalizedWord = word
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedWord.count >= 2 else { return [] }

        return try await libraryService.adviseChord(
            for: normalizedWord,
            profile: .cc2A1,
            allowExistingOutput: true,
            limit: limit
        )
    }

    func acceptAdvisorCandidate(_ candidate: Candidate, word: String) async {
        let output = word.trimmingCharacters(in: .whitespacesAndNewlines)
        await addChord(
            input: candidate.inputKeys.joined(separator: ","),
            output: output,
            profile: .cc2A1,
            deploymentTarget: .device,
            enabled: true,
            source: "advisor"
        )
    }

    func importChordJSON() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let count = try await libraryService.importCharaChordFile(
                at: url,
                profile: .cc2A1,
                deploymentTarget: .device,
                source: "M4G JSON"
            )
            await refresh()
            statusText = "Imported \(count) chords from \(url.lastPathComponent)"
        } catch {
            lastError = error.localizedDescription
            statusText = "Import failed"
        }
    }

    func exportChordJSON() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "chords-M4G-\(Self.timestamp()).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let file = try await libraryService.exportCharaChordFile(profile: .cc2A1)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(file).write(to: url, options: .atomic)
            statusText = "Exported \(file.chords.count) chords"
        } catch {
            lastError = error.localizedDescription
            statusText = "Export failed"
        }
    }

    func syncPrimaryDevice() async {
        do {
            guard let deviceSource else {
                lastError = "No primary device source is loaded."
                return
            }
            guard !pendingDeviceMutations.isEmpty else {
                statusText = "No queued M4G changes"
                return
            }
            lastError = nil
            let portPath = deviceSource.portPath
            let explicitPending = pendingDeviceMutations
            let plan = DeviceSyncService.buildExplicitSyncPlan(
                current: [],
                explicitMutations: explicitPending.map(\.mutation)
            )
            statusText = "Uploading \(plan.upsertCount) adds/updates and \(plan.deleteCount) deletes…"
            try await applyDeviceMutations(explicitPending, portPath: portPath)
            pendingDeviceMutations.removeAll()
            do {
                try await savePendingDeviceMutations()
            } catch {
                lastError = error.localizedDescription
                statusText = "Queued M4G changes synced; queue cleanup failed"
                return
            }
            statusText = "Queued M4G changes synced (\(plan.upsertCount) upserted, \(plan.deleteCount) deleted)"
            await refresh()
        } catch {
            lastError = error.localizedDescription
            statusText = "Queued M4G sync failed"
        }
    }

    func saveSettings() async {
        do {
            try await libraryService.setSetting("engine.enabled", value: engineEnabled ? "1" : "0")
            try await libraryService.setSetting("engine.profile", value: activeSoftwareProfile.rawValue)
            try await libraryService.setSetting("engine.excluded_bundle_ids", value: excludedBundleIDsText)
            engine.updateConfiguration(
                EngineConfiguration(
                    enabled: engineEnabled,
                    activeProfile: activeSoftwareProfile,
                    excludedBundleIDs: parsedExcludedBundleIDs()
                )
            )
            let activeChords = try await libraryService.activeChords(for: activeSoftwareProfile)
            engine.updateChords(activeChords)
            statusText = "Settings saved"
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadSettings() async {
        do {
            if let enabled = try await libraryService.stringSetting(forKey: "engine.enabled") {
                engineEnabled = enabled == "1"
            }
            if let profile = try await libraryService.stringSetting(forKey: "engine.profile"),
               let parsed = ErgonomicProfile(rawValue: profile) {
                activeSoftwareProfile = parsed
            }
            excludedBundleIDsText = try await libraryService.stringSetting(forKey: "engine.excluded_bundle_ids") ?? ""
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func configureLaunchAtLogin() async {
        canManageLaunchAtLogin = launchAtLoginController.isInstalledApplication
        guard canManageLaunchAtLogin else {
            applyLaunchAtLoginState(.unavailable)
            return
        }

        let attempted = try? await libraryService.stringSetting(
            forKey: Self.launchAtLoginAttemptedSettingKey
        )
        if attempted == nil || launchAtLoginController.serviceWasNotFound {
            applyLaunchAtLoginState(launchAtLoginController.setEnabled(true))
            try? await libraryService.setSetting(
                Self.launchAtLoginAttemptedSettingKey,
                value: "1"
            )
        } else {
            applyLaunchAtLoginState(launchAtLoginController.currentState())
        }
    }

    private func applyLaunchAtLoginState(_ state: LaunchAtLoginState) {
        launchAtLoginEnabled = state.isEnabled
        launchAtLoginNeedsApproval = state.needsApproval
        launchAtLoginStatusText = state.description
        if case .error(let message) = state {
            lastError = message
        }
    }

    private func loadPendingDeviceMutations() async {
        do {
            guard let value = try await libraryService.stringSetting(forKey: Self.pendingDeviceMutationsSettingKey),
                  let data = value.data(using: .utf8) else {
                return
            }
            let decoded = try JSONDecoder().decode([PendingDeviceMutation].self, from: data)
            pendingDeviceMutations = Self.coalescedPendingDeviceMutations(decoded)
        } catch {
            lastError = error.localizedDescription
            statusText = "Could not load pending M4G changes"
        }
    }

    private func savePendingDeviceMutations() async throws {
        let data = try JSONEncoder().encode(pendingDeviceMutations)
        let value = String(decoding: data, as: UTF8.self)
        try await libraryService.setSetting(Self.pendingDeviceMutationsSettingKey, value: value)
    }

    private func applyDeviceMutations(_ pendingMutations: [PendingDeviceMutation], portPath: String?) async throws {
        guard !pendingMutations.isEmpty else { return }
        guard let portPath else {
            throw NSError(
                domain: "Chordsmith.DeviceSync",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No primary device source is loaded."]
            )
        }

        let deviceService = self.deviceService
        let plan = DeviceSyncService.buildExplicitSyncPlan(
            current: [],
            explicitMutations: pendingMutations.map(\.mutation)
        )
        guard !plan.mutations.isEmpty else { return }

        try await Task.detached(priority: .userInitiated) {
            try deviceService.applyMutations(plan.mutations, to: portPath)
        }.value
    }

    private static func coalescedPendingDeviceMutations(_ mutations: [PendingDeviceMutation]) -> [PendingDeviceMutation] {
        var orderedInputs: [String] = []
        var byInput: [String: PendingDeviceMutation] = [:]

        for mutation in mutations {
            let input = mutation.inputIdentity
            if byInput[input] == nil {
                orderedInputs.append(input)
            }
            byInput[input] = mutation
        }

        return orderedInputs.compactMap { byInput[$0] }
    }

    private static func isDeviceTarget(_ target: DeploymentTarget) -> Bool {
        target == .device || target == .both
    }

    static func isQuickEditablePlainDeviceChord(_ chord: ChordEntry) -> Bool {
        isDeviceTarget(chord.deploymentTarget)
            && chord.profile == .cc2A1
            && chord.actionFlags.isEmpty
            && chord.plainOutput != nil
    }

    private static func deviceInputIdentity(_ chord: ChordEntry) -> String? {
        if let encodedInput = chord.encodedInput {
            return encodedInput.uppercased()
        }
        if let rawInputActions = chord.rawInputActions {
            return ActionCodec.stringifyChordActions(rawInputActions).uppercased()
        }
        return ActionCodec.chordActions(forTokens: chord.inputKeys)
            .map(ActionCodec.stringifyChordActions)?
            .uppercased()
    }

    private func parsedExcludedBundleIDs() -> Set<String> {
        Set(
            excludedBundleIDsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "_")
    }
}
