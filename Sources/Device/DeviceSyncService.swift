import Foundation
import Library

public struct DeviceSyncPlan: Sendable, Hashable {
    public let mutations: [DeviceMutation]

    public init(mutations: [DeviceMutation]) {
        self.mutations = mutations
    }

    public var upsertCount: Int {
        mutations.reduce(0) { count, mutation in
            if case .upsert = mutation {
                return count + 1
            }
            return count
        }
    }

    public var deleteCount: Int {
        mutations.reduce(0) { count, mutation in
            if case .delete = mutation {
                return count + 1
            }
            return count
        }
    }
}

public enum DeviceSyncService {
    public static func buildSyncPlan(current: [DeviceChordRecord], desired: [ChordEntry]) -> DeviceSyncPlan {
        let currentByInput = keyedRecords(current)
        let desiredRecords = desired.map(DeviceChordRecord.init(chord:))
        let desiredByInput = keyedRecords(desiredRecords)

        var mutations: [DeviceMutation] = []

        for (input, desiredRecord) in desiredByInput {
            if let currentRecord = currentByInput[input] {
                if encodedPhrase(currentRecord) != encodedPhrase(desiredRecord) {
                    mutations.append(.upsert(desiredRecord))
                }
            } else {
                mutations.append(.upsert(desiredRecord))
            }
        }

        for (input, currentRecord) in currentByInput where desiredByInput[input] == nil {
            mutations.append(.delete(currentRecord))
        }

        return DeviceSyncPlan(mutations: mutations)
    }

    public static func buildAdditiveSyncPlan(current: [DeviceChordRecord], desired: [ChordEntry]) -> DeviceSyncPlan {
        let currentByInput = keyedRecords(current)
        let desiredRecords = desired.map(DeviceChordRecord.init(chord:))
        let desiredByInput = keyedRecords(desiredRecords)

        var mutations: [DeviceMutation] = []

        for (input, desiredRecord) in desiredByInput {
            if let currentRecord = currentByInput[input] {
                if encodedPhrase(currentRecord) != encodedPhrase(desiredRecord) {
                    mutations.append(.upsert(desiredRecord))
                }
            } else {
                mutations.append(.upsert(desiredRecord))
            }
        }

        return DeviceSyncPlan(mutations: mutations)
    }

    public static func buildExplicitSyncPlan(current: [DeviceChordRecord], explicitMutations: [DeviceMutation]) -> DeviceSyncPlan {
        let currentByInput = keyedRecords(current)
        var mutations: [DeviceMutation] = []
        var seenInputs = Set<String>()

        for mutation in explicitMutations.reversed() {
            let record: DeviceChordRecord
            switch mutation {
            case .upsert(let upsertRecord):
                record = upsertRecord
            case .delete(let deleteRecord):
                record = deleteRecord
            }

            let input = identity(record)
            guard seenInputs.insert(input).inserted else { continue }

            switch mutation {
            case .upsert(let desiredRecord):
                if let currentRecord = currentByInput[input] {
                    if encodedPhrase(currentRecord) != encodedPhrase(desiredRecord) {
                        mutations.insert(.upsert(desiredRecord), at: 0)
                    }
                } else {
                    mutations.insert(.upsert(desiredRecord), at: 0)
                }
            case .delete(let deletedRecord):
                mutations.insert(.delete(deletedRecord), at: 0)
            }
        }

        return DeviceSyncPlan(mutations: mutations)
    }

    private static func keyedRecords(_ records: [DeviceChordRecord]) -> [String: DeviceChordRecord] {
        records.reduce(into: [String: DeviceChordRecord]()) { result, record in
            result[identity(record)] = record
        }
    }

    private static func identity(_ record: DeviceChordRecord) -> String {
        if let rawInput = record.rawInput, rawInput.count == 32 {
            return "raw:\(rawInput.uppercased())"
        }
        if let actions = record.rawInputActions {
            return "raw:\(ActionCodec.stringifyChordActions(actions))"
        }
        return "text:\(ChordEntry.normalizeInputKeys(record.inputKeys))"
    }

    private static func encodedPhrase(_ record: DeviceChordRecord) -> String {
        if let rawOutput = record.rawOutput {
            return rawOutput.uppercased()
        }
        if let actions = record.rawPhraseActions {
            return ActionCodec.stringifyPhraseActions(actions)
        }
        return ActionCodec.stringifyPhraseActions(ActionCodec.phraseActions(forPlainText: record.output))
    }
}
