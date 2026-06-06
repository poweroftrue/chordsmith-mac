import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import Foundation
import Library

public struct EngineConfiguration: Sendable {
    public var enabled: Bool
    public var activeProfile: ErgonomicProfile
    public var excludedBundleIDs: Set<String>

    public init(enabled: Bool = true, activeProfile: ErgonomicProfile = .ansiQwerty, excludedBundleIDs: Set<String> = []) {
        self.enabled = enabled
        self.activeProfile = activeProfile
        self.excludedBundleIDs = excludedBundleIDs
    }
}

private struct PendingSession {
    let startedAt: Date
    var tokens: [String]
    var keyCodes: [CGKeyCode]
    var events: [ReplayedEvent]
}

@MainActor
public final class ChordEngine: ObservableObject {
    @Published public private(set) var isRunning = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var configuration: EngineConfiguration
    private let injector: EventInjector
    private let recorder: TypingRecorder
    private var chordMap: [String: ChordEntry] = [:]
    private var pendingSession: PendingSession?
    private var resolutionWorkItem: DispatchWorkItem?
    private var suppressedReleases: Set<CGKeyCode> = []

    public init(configuration: EngineConfiguration = EngineConfiguration(), recorder: TypingRecorder, injector: EventInjector = EventInjector()) {
        self.configuration = configuration
        self.recorder = recorder
        self.injector = injector
    }

    public func updateConfiguration(_ configuration: EngineConfiguration) {
        self.configuration = configuration
    }

    public func updateChords(_ chords: [ChordEntry]) {
        if chords.isEmpty {
            resolvePendingSession()
        }
        chordMap = Dictionary(uniqueKeysWithValues: chords.map { ($0.normalizedInput, $0) })
    }

    public func start() {
        guard !isRunning else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<ChordEngine>.fromOpaque(refcon).takeUnretainedValue()
            return engine.handleEvent(proxy: proxy, type: type, event: event)
        }

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: pointer
        ) else {
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    public func stop() {
        resolutionWorkItem?.cancel()
        resolutionWorkItem = nil
        pendingSession = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == EventInjector.tag {
            return Unmanaged.passUnretained(event)
        }

        guard configuration.enabled,
              !chordMap.isEmpty,
              !IsSecureEventInputEnabled(),
              !isExcludedFrontmostApp() else {
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyUp, suppressedReleases.contains(keyCode) {
            suppressedReleases.remove(keyCode)
            return nil
        }

        if KeyMap.modifierKeyCodes.contains(keyCode) {
            resolvePendingSession()
            return Unmanaged.passUnretained(event)
        }

        guard let token = KeyMap.token(for: keyCode, profile: configuration.activeProfile) else {
            resolvePendingSession()
            return Unmanaged.passUnretained(event)
        }

        var session = pendingSession ?? PendingSession(startedAt: .now, tokens: [], keyCodes: [], events: [])

        if type == .keyDown {
            if !session.keyCodes.contains(keyCode) {
                session.keyCodes.append(keyCode)
                session.tokens.append(token)
            }
        }

        session.events.append(ReplayedEvent(keyCode: keyCode, isKeyDown: type == .keyDown, flags: event.flags))
        pendingSession = session
        rescheduleResolution(for: session)
        return nil
    }

    private func rescheduleResolution(for session: PendingSession) {
        resolutionWorkItem?.cancel()
        let delay = threshold(for: session.keyCodes.count)
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.resolvePendingSession()
            }
        }
        resolutionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func resolvePendingSession() {
        resolutionWorkItem?.cancel()
        resolutionWorkItem = nil

        guard let session = pendingSession else { return }
        pendingSession = nil
        suppressedReleases.formUnion(session.keyCodes)

        let normalizedInput = ChordEntry.normalizeInputKeys(session.tokens)
        let endedAt = Date()

        if let chord = chordMap[normalizedInput] {
            if looksLikeKeyCombo(chord.output) {
                injector.injectKeyCombo(chord.output, profile: configuration.activeProfile)
            } else {
                injector.injectText(chord.output)
            }
            Task {
                await recorder.recordChordOutput(chord.output, startedAt: session.startedAt, endedAt: endedAt)
            }
        } else {
            injector.replay(events: session.events)
            let literalText = session.tokens.compactMap { KeyMap.character(for: $0) }.joined()
            if !literalText.isEmpty {
                Task {
                    await recorder.recordLiteralText(literalText, startedAt: session.startedAt, endedAt: endedAt)
                }
            }
        }
    }

    private func threshold(for count: Int) -> TimeInterval {
        switch count {
        case ...1:
            return 0.05
        case 2:
            return 0.05
        case 3:
            return 0.075
        case 4:
            return 0.1
        default:
            return 0.125
        }
    }

    private func looksLikeKeyCombo(_ output: String) -> Bool {
        let parts = output.split(separator: "+")
        guard parts.count >= 2 else { return false }
        let modifiers = Set(["shift", "cmd", "command", "option", "alt", "control", "ctrl"])
        return parts.dropLast().allSatisfy { modifiers.contains($0.lowercased()) }
    }

    private func isExcludedFrontmostApp() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return isExcludedBundleID(bundleID)
    }

    func debugThreshold(for count: Int) -> TimeInterval {
        threshold(for: count)
    }

    func debugMatch(tokens: [String]) -> ChordEntry? {
        chordMap[ChordEntry.normalizeInputKeys(tokens)]
    }

    func debugShouldInterceptKeyboardEvents() -> Bool {
        configuration.enabled && !chordMap.isEmpty
    }

    func debugIsExcluded(bundleID: String) -> Bool {
        isExcludedBundleID(bundleID)
    }

    private func isExcludedBundleID(_ bundleID: String) -> Bool {
        if configuration.excludedBundleIDs.contains(bundleID) {
            return true
        }
        return Bundle.main.bundleIdentifier == bundleID
    }
}
