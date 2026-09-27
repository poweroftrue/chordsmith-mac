import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Library
import OSLog

/// One replacement the engine made, for stats, the recorder and learning.
public struct ShorthandEvent: Sendable {
    public let kind: ShorthandTyper.ReplacementKind
    public let typed: String
    public let output: String
    public let trigger: String
    public let chordID: UUID?
    public let savedKeystrokes: Int
    public let at: Date
}

public struct ShorthandSettings: Equatable, Sendable {
    public var enabled = true
    /// Stay out of the way while the Master Forge is plugged in: it has
    /// real chords.
    public var onlyWhenForgeUnplugged = true
    public var expandOnPunctuation = true
    public var undoWithBackspace = true
    public var excludedBundleIDs: Set<String> = []

    public init(
        enabled: Bool = true,
        onlyWhenForgeUnplugged: Bool = true,
        expandOnPunctuation: Bool = true,
        undoWithBackspace: Bool = true,
        excludedBundleIDs: Set<String> = []
    ) {
        self.enabled = enabled
        self.onlyWhenForgeUnplugged = onlyWhenForgeUnplugged
        self.expandOnPunctuation = expandOnPunctuation
        self.undoWithBackspace = undoWithBackspace
        self.excludedBundleIDs = excludedBundleIDs
    }

    public static let storageKeys = (
        enabled: "shorthand.enabled",
        onlyWhenForgeUnplugged: "shorthand.only_when_forge_unplugged",
        expandOnPunctuation: "shorthand.expand_on_punctuation",
        undoWithBackspace: "shorthand.undo_with_backspace",
        excludedBundleIDs: "shorthand.excluded_bundle_ids"
    )
}

/// Laptop shorthand on a dedicated thread. Keys are never held back: the
/// tap only swallows a trigger key when the letters before it are a
/// shorthand, then deletes the letters and types the chord's output.
///
/// Unlike chord detection, nothing waits on a timer, so typing never lags,
/// shortcuts and key repeat are untouched, and a stalled main thread can't
/// slow the keyboard.
public final class ShorthandEngine: @unchecked Sendable {
    private struct Shared {
        var settings = ShorthandSettings()
        var matcher = ShorthandMatcher.empty
        var forgeConnected = false
        var frontmostBundleID: String?
        var layoutIsASCII = true
        var keyMap: [Character: (keyCode: CGKeyCode, shift: Bool)] = [:]
        var resetRequested = false
    }

    private let lock = NSLock()
    private var shared = Shared()
    private let logger = Logger(subsystem: "com.poweroftrue.chordsmith", category: "Shorthand")
    private let ownBundleID = Bundle.main.bundleIdentifier

    // Touched only on the tap thread.
    private var typer = ShorthandTyper()
    private var suppressedKeyUps: Set<CGKeyCode> = []
    private var eventTap: CFMachPort?
    private var tapRunLoop: CFRunLoop?

    private var thread: Thread?
    private var observers: [NSObjectProtocol] = []
    private var distributedObserver: NSObjectProtocol?

    /// Called on the tap thread after each replacement.
    public var onEvent: (@Sendable (ShorthandEvent) -> Void)?

    public init() {}

    // MARK: Control (main thread)

    public var isRunning: Bool { lock.withLock { eventTap != nil } }

    /// Replacing text needs Accessibility access.
    public static func hasPermission(prompt: Bool = false) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    /// Starts the tap. Returns false when Accessibility access is missing or
    /// the tap could not be created.
    @MainActor
    @discardableResult
    public func start() -> Bool {
        if isRunning { return true }
        guard Self.hasPermission() else {
            logger.notice("Shorthand paused: Accessibility access is not granted")
            return false
        }
        observeEnvironment()
        refreshKeyboardLayout()

        let ready = DispatchSemaphore(value: 0)
        let started = LockedFlag()
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            if self.installTap() {
                started.set(true)
                ready.signal()
                CFRunLoopRun()
            } else {
                ready.signal()
            }
        }
        thread.name = "Chordsmith shorthand"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
        guard started.value else {
            logger.error("Shorthand could not create its keyboard tap")
            return false
        }
        self.thread = thread
        logger.notice("Shorthand started")
        return true
    }

    @MainActor
    public func stop() {
        let (tap, runLoop) = lock.withLock { (eventTap, tapRunLoop) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        lock.withLock {
            eventTap = nil
            tapRunLoop = nil
        }
        thread = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        if let distributedObserver { DistributedNotificationCenter.default().removeObserver(distributedObserver) }
        distributedObserver = nil
    }

    public func update(settings: ShorthandSettings) {
        lock.withLock {
            shared.settings = settings
            shared.resetRequested = true
        }
    }

    public func update(matcher: ShorthandMatcher) {
        lock.withLock { shared.matcher = matcher }
    }

    public func setForgeConnected(_ connected: Bool) {
        lock.withLock {
            if shared.forgeConnected != connected { shared.resetRequested = true }
            shared.forgeConnected = connected
        }
    }

    /// Whether shorthands would replace text in the frontmost app right now.
    public var isActiveNow: Bool {
        lock.withLock { isActive(shared) } && isRunning && !IsSecureEventInputEnabled()
    }

    public var frontmostBundleID: String? { lock.withLock { shared.frontmostBundleID } }

    @MainActor
    private func observeEnvironment() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        lock.withLock { shared.frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.lock.withLock {
                self?.shared.frontmostBundleID = app?.bundleIdentifier
                self?.shared.resetRequested = true
            }
        })
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeyboardLayout() }
        }
    }

    /// Non-Latin layouts (Arabic, Hebrew, …) turn shorthand off; the key
    /// map lets output use real key codes, which terminals and remote
    /// desktops need.
    @MainActor
    private func refreshKeyboardLayout() {
        var isASCII = true
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) {
            isASCII = CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
        }
        let keyMap = Self.currentKeyMap()
        lock.withLock {
            shared.layoutIsASCII = isASCII
            shared.keyMap = keyMap
            shared.resetRequested = true
        }
    }

    static func currentKeyMap() -> [Character: (keyCode: CGKeyCode, shift: Bool)] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return [:] }
        var map: [Character: (keyCode: CGKeyCode, shift: Bool)] = [:]
        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            for shift in [false, true] {
                let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                for keyCode in 0..<UInt16(128) {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                        OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, 4, &length, &characters
                    )
                    guard status == noErr, length == 1,
                          let scalar = Unicode.Scalar(characters[0]), scalar.value >= 0x20, scalar.value != 0x7F else { continue }
                    let character = Character(scalar)
                    if map[character] == nil { map[character] = (CGKeyCode(keyCode), shift) }
                }
            }
        }
        return map
    }

    // MARK: Tap thread

    private func installTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<ShorthandEngine>.fromOpaque(refcon).takeUnretainedValue()
            return engine.handle(proxy: proxy, type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.withLock {
            eventTap = tap
            tapRunLoop = runLoop
        }
        return true
    }

    private func isActive(_ state: Shared) -> Bool {
        guard state.settings.enabled, state.layoutIsASCII, !state.matcher.isEmpty else { return false }
        if state.settings.onlyWhenForgeUnplugged && state.forgeConnected { return false }
        if let bundleID = state.frontmostBundleID {
            if bundleID == ownBundleID || state.settings.excludedBundleIDs.contains(bundleID) { return false }
        }
        return true
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ eventTap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            typer.reset()
            logger.notice("Shorthand tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)")
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == EventInjector.tag { return pass }

        switch type {
        case .keyUp:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            return suppressedKeyUps.remove(keyCode) != nil ? nil : pass
        case .keyDown:
            break
        default:
            typer.reset()
            return pass
        }

        let state: Shared = lock.withLock {
            let copy = shared
            shared.resetRequested = false
            return copy
        }
        if state.resetRequested { typer.reset() }
        guard isActive(state), !IsSecureEventInputEnabled() else {
            typer.reset()
            return pass
        }

        let key = Self.classify(event)
        let options = ShorthandTyper.Options(
            expandOnPunctuation: state.settings.expandOnPunctuation,
            undoWithBackspace: state.settings.undoWithBackspace
        )
        let matcher = state.matcher
        guard case .replace(let replacement) = typer.handle(key, options: options, match: { matcher.match($0) }) else {
            return pass
        }

        perform(replacement, proxy: proxy, keyMap: state.keyMap)
        suppressedKeyUps.insert(CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)))
        onEvent?(ShorthandEvent(
            kind: replacement.kind,
            typed: replacement.typed,
            output: replacement.output,
            trigger: replacement.trigger,
            chordID: replacement.chordID,
            savedKeystrokes: replacement.savedKeystrokes,
            at: Date()
        ))
        return nil
    }

    static func classify(_ event: CGEvent) -> ShorthandTyper.Key {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags
        switch keyCode {
        case kVK_Delete:
            if flags.contains(.maskCommand) || flags.contains(.maskAlternate) { return .deleteWord }
            if flags.contains(.maskControl) { return .boundary }
            return .backspace(isRepeat: isRepeat)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape, kVK_ForwardDelete,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return .boundary
        default:
            break
        }
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            return .boundary
        }
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return .boundary }
        let text = String(utf16CodeUnits: buffer, count: length)
        if text.unicodeScalars.allSatisfy({ (0xF700...0xF8FF).contains($0.value) || $0.value < 0x20 }) {
            return .boundary
        }
        let seconds = Double(EventClock.uptimeNanoseconds(forEventTimestamp: event.timestamp)) / 1_000_000_000
        return .text(text, isRepeat: isRepeat, at: seconds)
    }

    /// Deletes the typed letters and types the replacement right behind the
    /// tap, so the events land in order before any key typed after them.
    /// Real key codes go with each character for apps that read key codes
    /// (terminals, remote desktops); others fall back to Unicode text.
    private func perform(_ replacement: ShorthandTyper.Replacement, proxy: CGEventTapProxy, keyMap: [Character: (keyCode: CGKeyCode, shift: Bool)]) {
        // No source: the events carry only the flags set here, never
        // whatever modifier you are still holding.
        let source: CGEventSource? = nil
        func post(keyCode: CGKeyCode, flags: CGEventFlags, text: [UniChar]?) {
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { continue }
                event.flags = flags
                if let text { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
                event.setIntegerValueField(.eventSourceUserData, value: EventInjector.tag)
                event.tapPostEvent(proxy)
            }
        }
        for _ in 0..<replacement.deleteCount {
            post(keyCode: CGKeyCode(kVK_Delete), flags: [], text: nil)
            usleep(800)
        }
        for character in replacement.insert {
            let units = Array(String(character).utf16)
            if let mapped = keyMap[character] {
                post(keyCode: mapped.keyCode, flags: mapped.shift ? .maskShift : [], text: units)
            } else {
                post(keyCode: CGKeyCode(kVK_Space), flags: [], text: units)
            }
            usleep(400)
        }
        logger.debug("Shorthand \(replacement.kind.rawValue, privacy: .public): \(replacement.typed, privacy: .private) → \(replacement.output, privacy: .private)")
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set(_ value: Bool) { lock.withLock { flag = value } }
}
