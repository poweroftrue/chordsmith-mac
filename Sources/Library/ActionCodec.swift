import Foundation

public struct ActionCode: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (lhs: ActionCode, rhs: ActionCode) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ChordFlag: String, Codable, CaseIterable, Sendable, Hashable {
    case macro
    case compound
    case cursor
    case mouse
    case hasNoAction = "no_action"
    case unknownAction = "unknown_action"
}

public struct ActionSequence: Codable, Hashable, Sendable {
    public let actions: [Int]

    public init(_ actions: [Int]) {
        self.actions = actions
    }
}

public struct ChordDisplay: Codable, Hashable, Sendable {
    public let inputTokens: [String]
    public let phraseTokens: [String]
    public let plainOutput: String?
    public let displayOutput: String
    public let flags: Set<ChordFlag>

    public init(inputTokens: [String], phraseTokens: [String], plainOutput: String?, displayOutput: String, flags: Set<ChordFlag>) {
        self.inputTokens = inputTokens
        self.phraseTokens = phraseTokens
        self.plainOutput = plainOutput
        self.displayOutput = displayOutput
        self.flags = flags
    }

    public var searchText: String {
        (
            inputTokens
            + phraseTokens
            + flags.map(\.rawValue)
            + [plainOutput ?? "", displayOutput]
        )
        .joined(separator: " ")
        .lowercased()
    }
}

public struct RawChordRecord: Codable, Hashable, Sendable {
    public let inputActions: [Int]
    public let phraseActions: [Int]
    public let encodedInput: String
    public let encodedPhrase: String
    public let display: ChordDisplay

    public init(inputActions: [Int], phraseActions: [Int]) {
        let normalizedInputActions = ActionCodec.normalizedChordActions(inputActions)
        self.inputActions = normalizedInputActions
        self.phraseActions = phraseActions
        self.encodedInput = ActionCodec.stringifyChordActions(normalizedInputActions)
        self.encodedPhrase = ActionCodec.stringifyPhraseActions(phraseActions)
        self.display = ActionCodec.display(inputActions: normalizedInputActions, phraseActions: phraseActions)
    }

    public init(encodedInput: String, encodedPhrase: String) {
        let inputActions = ActionCodec.parseChordActions(encodedInput)
        let phraseActions = ActionCodec.parsePhraseActions(encodedPhrase)
        self.init(inputActions: inputActions, phraseActions: phraseActions)
    }
}

public struct CharaChordPair: Codable, Hashable, Sendable {
    public let input: [Int]
    public let phrase: [Int]

    public init(input: [Int], phrase: [Int]) {
        self.input = input
        self.phrase = phrase
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        input = try container.decode([Int].self)
        phrase = try container.decode([Int].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(input)
        try container.encode(phrase)
    }
}

public struct CharaChordFile: Codable, Hashable, Sendable {
    public let charaVersion: Int
    public let type: String
    public let chords: [CharaChordPair]

    public init(charaVersion: Int = 1, type: String = "chords", chords: [CharaChordPair]) {
        self.charaVersion = charaVersion
        self.type = type
        self.chords = chords
    }
}

public enum ActionCodec {
    public static func normalizedChordActions(_ actions: [Int]) -> [Int] {
        if actions.count == 12 {
            return actions.map { $0 & 0x3FF }
        }

        if actions.count > 12 {
            return Array(actions.suffix(12)).map { $0 & 0x3FF }
        }

        return Array(repeating: 0, count: 12 - actions.count) + actions.map { $0 & 0x3FF }
    }

    public static func activeChordActions(_ actions: [Int]) -> [Int] {
        let normalized = normalizedChordActions(actions)
        guard let lastZero = normalized.lastIndex(of: 0) else {
            return normalized
        }
        return Array(normalized.suffix(from: normalized.index(after: lastZero)))
    }

    public static func parseChordActions(_ hex: String) -> [Int] {
        guard let value = UInt128Storage(hex, radix: 16) else {
            return normalizedChordActions([])
        }

        var native = value
        var actions: [Int] = []
        actions.reserveCapacity(12)
        for _ in 0..<12 {
            actions.append(native.lowBits(mask: 0x3FF))
            native.shiftRight(by: 10)
        }
        return actions
    }

    public static func stringifyChordActions(_ actions: [Int]) -> String {
        var native = UInt128Storage(0)
        let normalized = normalizedChordActions(actions)
        for index in 1...normalized.count {
            let action = normalized[normalized.count - index] & 0x3FF
            native.formUnion(UInt128Storage(UInt64(action), shiftedLeftBy: (12 - index) * 10))
        }
        return native.hexString
    }

    public static func parsePhraseActions(_ hex: String) -> [Int] {
        guard !hex.isEmpty else { return [] }

        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }

        return decompressPhraseBytes(bytes)
    }

    public static func stringifyPhraseActions(_ actions: [Int]) -> String {
        compressPhraseActions(actions)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    public static func compressPhraseActions(_ actions: [Int]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(actions.count * 2)
        for action in actions {
            let clamped = action & 0x1FFF
            if clamped > 0xFF {
                bytes.append(UInt8((clamped >> 8) & 0xFF))
            }
            bytes.append(UInt8(clamped & 0xFF))
        }
        return bytes
    }

    public static func decompressPhraseBytes(_ bytes: [UInt8]) -> [Int] {
        var actions: [Int] = []
        var index = 0
        while index < bytes.count {
            var action = Int(bytes[index])
            if action > 0 && action < 32 && index + 1 < bytes.count {
                index += 1
                action = (action << 8) | Int(bytes[index])
            }
            actions.append(action)
            index += 1
        }
        return actions
    }

    public static func hashChord(_ actions: [Int]) -> Int {
        let encoded = parseHexBytes(stringifyChordActions(actions))
        var hash = UInt32(2_166_136_261)
        for byte in encoded {
            hash = UInt32(truncatingIfNeeded: UInt64(hash ^ UInt32(byte)) &* 16_777_619)
        }
        if hash & 0xFF == 0xFF {
            hash ^= 0xFF
        }
        return Int(hash & 0x3FFF_FFFF)
    }

    public static func display(inputActions: [Int], phraseActions: [Int]) -> ChordDisplay {
        let normalizedInput = normalizedChordActions(inputActions)
        let activeInput = activeChordActions(normalizedInput)
        let inputTokens = activeInput.map { ActionCatalog.token(for: $0) }
        let phraseTokens = phraseActions.map { ActionCatalog.token(for: $0) }
        let plainOutput = ActionCatalog.plainText(for: phraseActions)
        let displayOutput = plainOutput ?? phraseTokens.map { "<\($0)>" }.joined()
        let flags = ActionCatalog.flags(inputActions: normalizedInput, phraseActions: phraseActions)

        return ChordDisplay(
            inputTokens: inputTokens,
            phraseTokens: phraseTokens,
            plainOutput: plainOutput,
            displayOutput: displayOutput,
            flags: flags
        )
    }

    public static func phraseActions(forPlainText text: String) -> [Int] {
        text.unicodeScalars.map { Int($0.value) }
    }

    public static func chordActions(forTokens tokens: [String]) -> [Int]? {
        let actions = tokens.compactMap { ActionCatalog.code(for: $0) }
        guard actions.count == tokens.count, !actions.isEmpty else { return nil }
        return normalizedChordActions(actions.sorted())
    }

    public static func parseHexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        return bytes
    }
}

public enum ActionCatalog {
    private static let namedCodes: [Int: String] = {
        var map: [Int: String] = [
            0: "NO_ACTION",
            32: "space",
            127: "DEL",
            256: "NO_CONCATENATOR",
            296: "ENTER",
            297: "ESC",
            298: "BKSP",
            299: "TAB",
            300: "KSC_SPACE",
            313: "CAPSLOCK",
            335: "ARROW_RT",
            336: "ARROW_LF",
            337: "ARROW_DN",
            338: "ARROW_UP",
            360: "F13",
            361: "F14",
            362: "F15",
            363: "F16",
            364: "F17",
            512: "LEFT_CTRL",
            513: "LEFT_SHIFT",
            514: "LEFT_ALT",
            515: "LEFT_GUI",
            516: "RIGHT_CTRL",
            517: "RIGHT_SHIFT",
            518: "RIGHT_ALT",
            519: "RIGHT_GUI",
            520: "RELEASE_MOD",
            521: "RELEASE_ALL",
            522: "RELEASE_KEYS",
            523: "PRESS_NEXT",
            524: "RELEASE_NEXT",
            528: "RESTART",
            530: "BOOT",
            532: "GTM",
            534: "IMPULSE",
            536: "DUP",
            538: "SPUR",
            540: "AMBILEFT",
            542: "AMBIRIGHT",
            544: "SPACERIGHT",
            548: "KM_1_L",
            549: "KM_1_R",
            550: "KM_2_L",
            551: "KM_2_R",
            552: "KM_3_L",
            553: "KM_3_R",
            558: "HOLD_COMPOUND",
            559: "RELEASE_COMPOUND",
            560: "MS_CLICK_BWD",
            561: "MS_CLICK_FWD",
            562: "MS_CLICK_LF",
            563: "MS_CLICK_RT",
            564: "MS_CLICK_MD",
            565: "MS_MOVE_RT",
            566: "MS_MOVE_LF",
            567: "MS_MOVE_DN",
            568: "MS_MOVE_UP",
            569: "MS_SCRL_RT",
            570: "MS_SCRL_LF",
            571: "MS_SCRL_DN",
            572: "MS_SCRL_UP",
            574: "JOIN",
            576: "ACTION_DELAY_1000",
            577: "ACTION_DELAY_100",
            578: "ACTION_DELAY_10",
            579: "ACTION_DELAY_1"
        ]

        for scalar in 33...126 where map[scalar] == nil {
            map[scalar] = String(UnicodeScalar(scalar)!)
        }
        for offset in 0..<26 {
            map[260 + offset] = "KEY_\(String(UnicodeScalar(65 + offset)!))"
        }
        for offset in 1...12 {
            map[313 + offset] = "F\(offset)"
        }
        return map
    }()

    private static let tokenCodes: [String: Int] = {
        var map: [String: Int] = [:]
        for (code, token) in namedCodes {
            map[token.lowercased()] = code
            map[token] = code
        }
        map[" "] = 32
        map["return"] = 296
        map["enter"] = 296
        map["escape"] = 297
        map["esc"] = 297
        map["backspace"] = 298
        map["bksp"] = 298
        map["delete"] = 127
        map["del"] = 127
        map["dup"] = 536
        return map
    }()

    public static func token(for code: Int) -> String {
        if let token = namedCodes[code] {
            return token
        }
        if 128...255 ~= code {
            return String(format: "CP1252_%02X", code)
        }
        if 256...511 ~= code {
            return String(format: "KSC_%02X", code - 256)
        }
        if 600...617 ~= code {
            return "CC1_3D_\(code - 600)"
        }
        return String(format: "0x%X", code)
    }

    public static func code(for token: String) -> Int? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 1, let scalar = trimmed.unicodeScalars.first, scalar.value <= 0x7F {
            return Int(scalar.value)
        }
        if trimmed.lowercased().hasPrefix("0x") {
            return Int(trimmed.dropFirst(2), radix: 16)
        }
        return tokenCodes[trimmed] ?? tokenCodes[trimmed.lowercased()]
    }

    public static func isKnown(_ code: Int) -> Bool {
        namedCodes[code] != nil || 128...511 ~= code || 600...617 ~= code
    }

    public static func isPrintable(_ code: Int) -> Bool {
        32...126 ~= code
    }

    public static func plainText(for actions: [Int]) -> String? {
        var output = ""
        for action in actions {
            if action == 0 {
                continue
            }
            guard isPrintable(action), let scalar = UnicodeScalar(action) else {
                return nil
            }
            output.append(Character(scalar))
        }
        return output
    }

    public static func flags(inputActions: [Int], phraseActions: [Int]) -> Set<ChordFlag> {
        var flags: Set<ChordFlag> = []
        let activeInputActions = ActionCodec.activeChordActions(inputActions)
        let allActions = activeInputActions + phraseActions

        if inputActions.first != 0 {
            flags.insert(.compound)
        }
        if activeInputActions.contains(0) || phraseActions.contains(0) {
            flags.insert(.hasNoAction)
        }
        if allActions.contains(where: { !isKnown($0) }) {
            flags.insert(.unknownAction)
        }
        if phraseActions.contains(where: { (512...524).contains($0) || [296, 299, 523, 524, 574].contains($0) }) {
            flags.insert(.macro)
        }
        if phraseActions.contains(where: { [335, 336, 337, 338].contains($0) }) {
            flags.insert(.cursor)
        }
        if allActions.contains(where: { (560...572).contains($0) }) {
            flags.insert(.mouse)
        }

        return flags
    }
}

private struct UInt128Storage: Sendable, Hashable {
    private var high: UInt64
    private var low: UInt64

    init(_ value: UInt64) {
        self.high = 0
        self.low = value
    }

    init(_ value: UInt64, shiftedLeftBy shift: Int) {
        if shift >= 64 {
            self.high = value << UInt64(shift - 64)
            self.low = 0
        } else if shift == 0 {
            self.high = 0
            self.low = value
        } else {
            self.high = value >> UInt64(64 - shift)
            self.low = value << UInt64(shift)
        }
    }

    init?(_ string: String, radix: Int) {
        guard radix == 16, string.count <= 32 else { return nil }
        let padded = String(repeating: "0", count: max(0, 32 - string.count)) + string
        guard let high = UInt64(padded.prefix(16), radix: 16),
              let low = UInt64(padded.suffix(16), radix: 16) else {
            return nil
        }
        self.high = high
        self.low = low
    }

    var hexString: String {
        String(format: "%016llX%016llX", high, low)
    }

    mutating func formUnion(_ other: UInt128Storage) {
        high |= other.high
        low |= other.low
    }

    mutating func shiftRight(by shift: Int) {
        guard shift > 0 else { return }
        if shift >= 64 {
            low = high >> UInt64(shift - 64)
            high = 0
        } else {
            low = (low >> UInt64(shift)) | (high << UInt64(64 - shift))
            high >>= UInt64(shift)
        }
    }

    func lowBits(mask: UInt64) -> Int {
        Int(low & mask)
    }
}
