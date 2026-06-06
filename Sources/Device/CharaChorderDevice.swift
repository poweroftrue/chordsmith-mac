import Foundation
import Library

public struct DeviceIdentity: Sendable, Hashable {
    public let portPath: String
    public let deviceName: String
    public let firmware: String
    public let chordCount: Int

    public init(portPath: String, deviceName: String, firmware: String, chordCount: Int) {
        self.portPath = portPath
        self.deviceName = deviceName
        self.firmware = firmware
        self.chordCount = chordCount
    }
}

public enum DeviceMutation: Sendable, Hashable {
    case upsert(DeviceChordRecord)
    case delete(DeviceChordRecord)
}

public enum DeviceParser {
    public static func parseIdentity(idResponse: String, versionResponse: String, chordCountResponse: String, path: String) -> DeviceIdentity? {
        let idParts = idResponse.split(separator: " ")
        let versionParts = versionResponse.split(separator: " ")
        let countParts = chordCountResponse.split(separator: " ")
        guard idParts.count >= 4,
              versionParts.count >= 2,
              countParts.count >= 3,
              let chordCount = Int(countParts[2]) else {
            return nil
        }

        return DeviceIdentity(
            portPath: path,
            deviceName: idParts.dropFirst().joined(separator: " "),
            firmware: versionParts.dropFirst().joined(separator: " "),
            chordCount: chordCount
        )
    }

    public static func parseChordResponse(_ response: String) -> DeviceChordRecord? {
        let parts = response.split(separator: " ")
        guard parts.count >= 5, parts[0] == "CML", parts[1] == "C1" else {
            return nil
        }

        let rawInput = String(parts[3])
        let rawOutput = String(parts[4])
        let rawRecord = RawChordRecord(encodedInput: rawInput, encodedPhrase: rawOutput)

        guard !rawRecord.display.inputTokens.isEmpty else { return nil }
        return DeviceChordRecord(
            inputKeys: rawRecord.display.inputTokens,
            output: rawRecord.display.plainOutput ?? rawRecord.display.displayOutput,
            rawInput: rawRecord.encodedInput,
            rawOutput: rawRecord.encodedPhrase,
            rawInputActions: rawRecord.inputActions,
            rawPhraseActions: rawRecord.phraseActions
        )
    }

    public static func encodeInput(_ inputKeys: [String]) -> String {
        ActionCodec.chordActions(forTokens: inputKeys).map(ActionCodec.stringifyChordActions)
            ?? String(repeating: "0", count: 32)
    }

    public static func encodeOutput(_ output: String) -> String {
        ActionCodec.stringifyPhraseActions(ActionCodec.phraseActions(forPlainText: output))
    }

    public static func deleteCommand(for record: DeviceChordRecord) -> String {
        let rawInput = encodedInput(for: record)
        return "CML C4 \(rawInput)"
    }

    public static func upsertCommand(for record: DeviceChordRecord) -> String {
        let rawInput = encodedInput(for: record)
        let rawOutput = encodedPhrase(for: record)
        return "CML C3 \(rawInput) \(rawOutput)"
    }

    public static func lookupCommand(for record: DeviceChordRecord) -> String {
        "CML C2 \(encodedInput(for: record))"
    }

    public static func encodedInput(for record: DeviceChordRecord) -> String {
        if let rawInput = record.rawInput, rawInput.count == 32 {
            return rawInput
        }
        if let actions = record.rawInputActions {
            return ActionCodec.stringifyChordActions(actions)
        }
        return encodeInput(record.inputKeys)
    }

    public static func encodedPhrase(for record: DeviceChordRecord) -> String {
        if let rawOutput = record.rawOutput {
            return rawOutput
        }
        if let actions = record.rawPhraseActions {
            return ActionCodec.stringifyPhraseActions(actions)
        }
        return encodeOutput(record.output)
    }
}

public final class CharaChorderDeviceService: @unchecked Sendable {
    public init() {}

    public func availablePorts() -> [String] {
        SerialPort.listCandidatePorts()
    }

    public func inspectPort(_ path: String) throws -> DeviceIdentity {
        let serialPort = SerialPort(path: path)
        try serialPort.open()
        defer { serialPort.close() }

        let id = try serialPort.sendCommand("ID", timeout: 3.0, flush: true)
        let version = try serialPort.sendCommand("VERSION", timeout: 3.0, flush: true)
        let count = try serialPort.sendCommand("CML C0", timeout: 4.0, flush: true)

        guard let identity = DeviceParser.parseIdentity(idResponse: id, versionResponse: version, chordCountResponse: count, path: path) else {
            throw SerialError.readFailed
        }
        return identity
    }

    public func preferredPrimarySnapshot(progress: ((Int, Int) -> Void)? = nil) throws -> (DeviceSource, [DeviceChordRecord])? {
        let identities = try availablePorts().compactMap { path -> DeviceIdentity? in
            try? inspectPort(path)
        }

        guard let preferred = identities.sorted(by: compareIdentities).first else {
            return nil
        }

        let source = DeviceSource(
            portPath: preferred.portPath,
            deviceName: preferred.deviceName,
            firmware: preferred.firmware,
            chordCount: preferred.chordCount,
            isPrimary: true
        )
        let snapshot = try snapshot(path: preferred.portPath, expectedCount: preferred.chordCount, progress: progress)
        return (source, snapshot)
    }

    public func snapshot(path: String, expectedCount: Int? = nil, progress: ((Int, Int) -> Void)? = nil) throws -> [DeviceChordRecord] {
        let serialPort = SerialPort(path: path)
        try serialPort.open()
        defer { serialPort.close() }

        let total: Int
        if let expectedCount {
            total = expectedCount
        } else {
            let response = try serialPort.sendCommand("CML C0", timeout: 4.0, flush: true)
            total = Int(response.split(separator: " ").last ?? "0") ?? 0
        }

        var records: [DeviceChordRecord] = []
        records.reserveCapacity(total)
        serialPort.flush()
        usleep(50_000)

        for index in 0..<total {
            if index % 50 == 0 {
                progress?(index, total)
            }
            let response = try serialPort.sendCommand("CML C1 \(index)", timeout: 2.0, flush: false)
            if let record = DeviceParser.parseChordResponse(response) {
                records.append(record)
            }
        }
        progress?(total, total)
        return records
    }

    public func applyMutations(_ mutations: [DeviceMutation], to path: String) throws {
        guard !mutations.isEmpty else { return }
        let serialPort = SerialPort(path: path)
        try serialPort.open()
        defer { serialPort.close() }

        serialPort.flush()
        for mutation in mutations {
            let command: String
            switch mutation {
            case .upsert(let record):
                _ = try serialPort.sendCommand(DeviceParser.lookupCommand(for: record), timeout: 5.0, flush: true)
                serialPort.drainInput()
                command = DeviceParser.upsertCommand(for: record)
            case .delete(let record):
                command = DeviceParser.deleteCommand(for: record)
            }
            _ = try serialPort.sendCommand(command, timeout: 5.0, flush: true)
            serialPort.drainInput()
        }
    }

    private func compareIdentities(_ lhs: DeviceIdentity, _ rhs: DeviceIdentity) -> Bool {
        let lhsIsPreferred = lhs.deviceName.contains("M4G ")
        let rhsIsPreferred = rhs.deviceName.contains("M4G ")
        if lhsIsPreferred != rhsIsPreferred {
            return lhsIsPreferred && !rhsIsPreferred
        }
        if lhs.chordCount != rhs.chordCount {
            return lhs.chordCount > rhs.chordCount
        }
        return lhs.portPath < rhs.portPath
    }
}

struct UInt128: ExpressibleByIntegerLiteral {
    var high: UInt64
    var low: UInt64

    init(_ value: Int) {
        self.high = 0
        self.low = UInt64(value)
    }

    init(integerLiteral value: UInt64) {
        self.high = 0
        self.low = value
    }

    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    init?(_ string: String, radix: Int) {
        guard radix == 16, string.count <= 32 else { return nil }
        let padded = String(repeating: "0", count: 32 - string.count) + string
        guard let high = UInt64(padded.prefix(16), radix: 16),
              let low = UInt64(padded.suffix(16), radix: 16) else {
            return nil
        }
        self.high = high
        self.low = low
    }

    static func & (lhs: UInt128, rhs: Int) -> Int {
        Int(lhs.low & UInt64(rhs))
    }

    static func |= (lhs: inout UInt128, rhs: UInt128) {
        lhs.low |= rhs.low
        lhs.high |= rhs.high
    }

    static func >>= (lhs: inout UInt128, rhs: Int) {
        if rhs >= 64 {
            lhs.low = lhs.high >> UInt64(rhs - 64)
            lhs.high = 0
        } else if rhs > 0 {
            lhs.low = (lhs.low >> UInt64(rhs)) | (lhs.high << UInt64(64 - rhs))
            lhs.high >>= UInt64(rhs)
        }
    }

    static func << (lhs: UInt128, rhs: Int) -> UInt128 {
        if rhs >= 64 {
            return UInt128(high: lhs.low << UInt64(rhs - 64), low: 0)
        }
        return UInt128(
            high: (lhs.high << UInt64(rhs)) | (lhs.low >> UInt64(64 - rhs)),
            low: lhs.low << UInt64(rhs)
        )
    }

    var hexString: String {
        String(format: "%016llX%016llX", high, low)
    }
}

private extension String {
    func leftPadding(toLength: Int, withPad character: Character) -> String {
        guard count < toLength else { return self }
        return String(repeating: String(character), count: toLength - count) + self
    }
}
