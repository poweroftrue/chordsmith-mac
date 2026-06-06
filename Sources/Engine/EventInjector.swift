import ApplicationServices
import Foundation
import Library

public final class EventInjector: @unchecked Sendable {
    public static let tag: Int64 = 0x4348415241574F52

    public init() {}

    public func injectText(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for scalar in text.unicodeScalars {
            guard let eventDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let eventUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            let codePoint = UInt16(scalar.value)
            eventDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: [codePoint])
            eventUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: [codePoint])
            eventDown.setIntegerValueField(.eventSourceUserData, value: Self.tag)
            eventUp.setIntegerValueField(.eventSourceUserData, value: Self.tag)
            eventDown.post(tap: .cghidEventTap)
            eventUp.post(tap: .cghidEventTap)
        }
    }

    public func injectKeyCombo(_ combo: String, profile: ErgonomicProfile) {
        let parts = combo.split(separator: "+").map { String($0).lowercased() }
        guard let keyToken = parts.last,
              let keyCode = KeyMap.keyCode(for: keyToken, profile: profile),
              let source = CGEventSource(stateID: .hidSystemState) else {
            injectText(combo)
            return
        }

        let modifierFlags = parts.dropLast().reduce(CGEventFlags()) { flags, part in
            switch part {
            case "cmd", "command":
                return flags.union(.maskCommand)
            case "shift":
                return flags.union(.maskShift)
            case "option", "alt":
                return flags.union(.maskAlternate)
            case "control", "ctrl":
                return flags.union(.maskControl)
            default:
                return flags
            }
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }

        keyDown.flags = modifierFlags
        keyUp.flags = modifierFlags
        keyDown.setIntegerValueField(.eventSourceUserData, value: Self.tag)
        keyUp.setIntegerValueField(.eventSourceUserData, value: Self.tag)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    public func replay(events: [ReplayedEvent]) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for event in events {
            guard let cgEvent = CGEvent(keyboardEventSource: source, virtualKey: event.keyCode, keyDown: event.isKeyDown) else {
                continue
            }
            cgEvent.flags = event.flags
            cgEvent.setIntegerValueField(.eventSourceUserData, value: Self.tag)
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}

public struct ReplayedEvent: Sendable {
    public let keyCode: CGKeyCode
    public let isKeyDown: Bool
    public let flags: CGEventFlags

    public init(keyCode: CGKeyCode, isKeyDown: Bool, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.isKeyDown = isKeyDown
        self.flags = flags
    }
}
