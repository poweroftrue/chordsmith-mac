import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import OSLog

@MainActor
public final class InputObservationEngine: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var needsInputMonitoringPermission = false
    @Published public private(set) var attributionStatusText = "Physical M4G detection stopped"

    private enum PendingRecorderEvent: Sendable {
        case text(String, keyCode: CGKeyCode, eventTimestamp: UInt64, capturedAt: Date)
        case backspace
        case delimiter(Date)
    }

    private enum ResolvedRecorderEvent: Sendable {
        case text(String, source: PhysicalInputSource, capturedAt: Date)
        case backspace
        case delimiter(Date)
        case flush
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let recorder: UsageRecorder
    private let inputSourceMonitor: HIDInputSourceMonitor
    private var pendingRecorderEvents: [PendingRecorderEvent] = []
    private var recorderWorkTask: Task<Void, Never>?
    private var drainWorkItem: DispatchWorkItem?
    private let attributionDelay: TimeInterval = 0.025
    private let logger = Logger(subsystem: "com.poweroftrue.chordsmith", category: "InputObservation")

    public init(recorder: UsageRecorder, inputSourceMonitor: HIDInputSourceMonitor = HIDInputSourceMonitor()) {
        self.recorder = recorder
        self.inputSourceMonitor = inputSourceMonitor
    }

    public func start() {
        guard !isRunning else { return }
        guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else {
            needsInputMonitoringPermission = true
            attributionStatusText = "Recorder needs Input Monitoring permission"
            logger.notice("Recorder paused: Input Monitoring permission is not granted")
            return
        }

        let inputSourceStatus = inputSourceMonitor.start()
        needsInputMonitoringPermission = false
        attributionStatusText = inputSourceStatus.displayText

        let mask = 1 << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<InputObservationEngine>.fromOpaque(refcon).takeUnretainedValue()
            return engine.handleEvent(proxy: proxy, type: type, event: event)
        }

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: pointer
        ) else {
            inputSourceMonitor.stop()
            attributionStatusText = "Recorder could not start its keyboard listener"
            logger.error("Recorder could not create its keyboard event tap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        logger.notice("Recorder started: \(self.attributionStatusText, privacy: .public)")
    }

    public func stop() {
        drainWorkItem?.cancel()
        drainWorkItem = nil
        drainPendingRecorderEvents()
        inputSourceMonitor.stop()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
        attributionStatusText = "Physical M4G detection stopped"
        appendRecorderWork([.flush])
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == EventInjector.tag ||
            IsSecureEventInputEnabled() ||
            isHostAppFrontmost() {
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        switch Int(keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            enqueue(.backspace)
            return Unmanaged.passUnretained(event)
        case kVK_Return, kVK_Tab, kVK_Escape:
            enqueue(.delimiter(.now))
            return Unmanaged.passUnretained(event)
        default:
            break
        }

        let shortcutFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        if !event.flags.intersection(shortcutFlags).isEmpty {
            enqueue(.delimiter(.now))
            return Unmanaged.passUnretained(event)
        }

        let text = keyboardText(from: event)
        guard !text.isEmpty else {
            enqueue(.delimiter(.now))
            return Unmanaged.passUnretained(event)
        }

        let now = Date()
        enqueue(
            .text(
                text,
                keyCode: keyCode,
                eventTimestamp: event.timestamp,
                capturedAt: now
            )
        )
        return Unmanaged.passUnretained(event)
    }

    private func enqueue(_ event: PendingRecorderEvent) {
        pendingRecorderEvents.append(event)
        guard drainWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.drainPendingRecorderEvents()
        }
        drainWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + attributionDelay, execute: workItem)
    }

    private func drainPendingRecorderEvents() {
        drainWorkItem?.cancel()
        drainWorkItem = nil
        guard !pendingRecorderEvents.isEmpty else { return }

        let resolved = pendingRecorderEvents.map { event -> ResolvedRecorderEvent in
            switch event {
            case .text(let text, let keyCode, let eventTimestamp, let capturedAt):
                let source = inputSourceMonitor.source(
                    forEventTimestamp: eventTimestamp,
                    virtualKeyCode: keyCode
                )
                return .text(text, source: source, capturedAt: capturedAt)
            case .backspace:
                return .backspace
            case .delimiter(let timestamp):
                return .delimiter(timestamp)
            }
        }
        pendingRecorderEvents.removeAll(keepingCapacity: true)
        appendRecorderWork(resolved)
    }

    private func appendRecorderWork(_ events: [ResolvedRecorderEvent]) {
        guard !events.isEmpty else { return }
        let previousTask = recorderWorkTask
        let recorder = recorder
        recorderWorkTask = Task {
            await previousTask?.value
            for event in events {
                switch event {
                case .text(let text, let source, let capturedAt):
                    await recorder.observeKeyboardText(
                        text,
                        source: source,
                        startedAt: capturedAt,
                        endedAt: capturedAt
                    )
                case .backspace:
                    await recorder.observeBackspace()
                case .delimiter(let timestamp):
                    await recorder.observeDelimiter(at: timestamp)
                case .flush:
                    await recorder.flush()
                }
            }
        }
    }

    private func keyboardText(from event: CGEvent) -> String {
        var actualLength = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &actualLength,
            unicodeString: &buffer
        )
        guard actualLength > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: actualLength)
    }

    private func isHostAppFrontmost() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let ownBundleID = Bundle.main.bundleIdentifier else {
            return false
        }
        return bundleID == ownBundleID
    }
}
