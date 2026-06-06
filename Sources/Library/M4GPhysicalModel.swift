import Foundation

enum M4GHand: String, Sendable {
    case left
    case right
}

enum M4GFinger: String, Sendable {
    case pinky
    case ring
    case middle
    case index
    case thumb
}

enum M4GDirection: String, Sendable, Comparable {
    case east = "e"
    case north = "n"
    case west = "w"
    case south = "s"

    static func < (lhs: M4GDirection, rhs: M4GDirection) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    private var sortOrder: Int {
        switch self {
        case .east: 0
        case .north: 1
        case .west: 2
        case .south: 3
        }
    }
}

struct M4GActionPlacement: Hashable, Sendable {
    let token: String
    let actionCode: Int
    let hand: M4GHand
    let finger: M4GFinger
    let thumbLane: String?
    let switchID: String
    let direction: M4GDirection
    let homeScore: Double
}

struct M4GConflictGroup: Hashable, Sendable {
    enum Kind: Sendable {
        case sameSwitch
        case sameThumbLane
    }

    let kind: Kind
    let label: String
    let tokens: Set<String>

    func reason(for collision: Set<String>) -> String {
        let collisionText = collision.sorted().joined(separator: ", ")
        switch kind {
        case .sameSwitch:
            return "Same-switch collision on \(label): \(collisionText)."
        case .sameThumbLane:
            return "Same \(label) conflict: \(collisionText)."
        }
    }
}

struct M4GPhysicalModel: Sendable {
    let placementsByToken: [String: [M4GActionPlacement]]
    let sameSwitchGroups: [[String]]
    let hardConflictGroups: [M4GConflictGroup]

    var bestPlacementsByToken: [String: M4GActionPlacement] {
        placementsByToken.mapValues { placements in
            placements.max { lhs, rhs in
                if lhs.homeScore == rhs.homeScore {
                    return lhs.switchID > rhs.switchID
                }
                return lhs.homeScore < rhs.homeScore
            }!
        }
    }

    static let defaultA1 = M4GPhysicalModel(layoutActions: defaultA1Layout)

    init(layoutActions: [Int] = Self.defaultA1Layout) {
        var placements: [String: [M4GActionPlacement]] = [:]
        var switchGroups: [[String]] = []
        var switchConflictGroups: [M4GConflictGroup] = []
        var thumbLaneGroups: [String: Set<String>] = [:]

        for switchDefinition in Self.officialSwitchGeometry {
            var switchTokens: [String] = []

            for (direction, slot) in switchDefinition.directions.sorted(by: { $0.key < $1.key }) {
                guard slot < layoutActions.count else { continue }
                let actionCode = layoutActions[slot]
                guard actionCode != 0 else { continue }

                let token = Self.normalizedToken(ActionCatalog.token(for: actionCode))
                let placement = M4GActionPlacement(
                    token: token,
                    actionCode: actionCode,
                    hand: switchDefinition.hand,
                    finger: switchDefinition.finger,
                    thumbLane: switchDefinition.thumbLane,
                    switchID: switchDefinition.id,
                    direction: direction,
                    homeScore: Self.homeScore(for: token, finger: switchDefinition.finger)
                )

                placements[token, default: []].append(placement)
                switchTokens.append(token)
            }

            let uniqueSwitchTokens = Array(Set(switchTokens)).sorted()
            if uniqueSwitchTokens.count > 1 {
                switchGroups.append(uniqueSwitchTokens)
                switchConflictGroups.append(
                    M4GConflictGroup(
                        kind: .sameSwitch,
                        label: switchDefinition.label,
                        tokens: Set(uniqueSwitchTokens)
                    )
                )
            }

            if let thumbLane = switchDefinition.thumbLane {
                thumbLaneGroups[thumbLane, default: []].formUnion(uniqueSwitchTokens)
            }
        }

        let thumbConflictGroups = thumbLaneGroups
            .sorted { $0.key < $1.key }
            .map { lane, tokens in
                M4GConflictGroup(
                    kind: .sameThumbLane,
                    label: lane,
                    tokens: tokens
                )
            }

        self.placementsByToken = placements
        self.sameSwitchGroups = switchGroups
        self.hardConflictGroups = switchConflictGroups + thumbConflictGroups
    }

    func bestPlacement(for token: String) -> M4GActionPlacement? {
        placementsByToken[Self.normalizedToken(token)]?.max { lhs, rhs in
            if lhs.homeScore == rhs.homeScore {
                return lhs.switchID > rhs.switchID
            }
            return lhs.homeScore < rhs.homeScore
        }
    }

    func hardConflictReasons(for tokens: [String]) -> [String] {
        let tokenSet = Set(tokens.map(Self.normalizedToken))
        return hardConflictGroups.compactMap { group in
            let collision = group.tokens.intersection(tokenSet)
            guard collision.count > 1 else { return nil }
            return group.reason(for: collision)
        }
    }

    static func normalizedToken(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func homeScore(for token: String, finger: M4GFinger) -> Double {
        let tokenScore: [String: Double] = [
            "a": 4, "t": 4, "r": 3.5, "e": 3.5, "s": 3, "n": 3, "l": 2.5,
            "d": 2.5, "h": 2.5, "p": 2, "f": 2, "c": 1.5, "m": 1.5,
            "k": 1, "v": 0.5, "i": 1, "o": 1, "u": 0.5, "y": 0.5,
            "g": 0, "w": 0, "b": -1, "x": -3, "q": -2, "z": -2,
            "dup": 1, ",": 1, ".": 1, ";": 0.5, "'": 0.5, "/": 0.5
        ]

        let fingerScore: Double
        switch finger {
        case .index: fingerScore = 1.0
        case .middle: fingerScore = 0.5
        case .ring: fingerScore = -0.25
        case .pinky: fingerScore = -0.75
        case .thumb: fingerScore = -0.5
        }

        return (tokenScore[token] ?? 0) + fingerScore
    }

    private struct SwitchDefinition: Sendable {
        let id: String
        let label: String
        let hand: M4GHand
        let finger: M4GFinger
        let thumbLane: String?
        let directions: [M4GDirection: Int]
    }

    private static let officialSwitchGeometry: [SwitchDefinition] = [
        .init(id: "left-ring-upper", label: "left ring upper switch", hand: .left, finger: .ring, thumbLane: nil, directions: [.east: 26, .north: 27, .west: 28, .south: 29]),
        .init(id: "left-middle-upper", label: "left middle upper switch", hand: .left, finger: .middle, thumbLane: nil, directions: [.east: 21, .north: 22, .west: 23, .south: 24]),
        .init(id: "right-middle-upper", label: "right middle upper switch", hand: .right, finger: .middle, thumbLane: nil, directions: [.west: 66, .north: 67, .east: 68, .south: 69]),
        .init(id: "right-ring-upper", label: "right ring upper switch", hand: .right, finger: .ring, thumbLane: nil, directions: [.west: 71, .north: 72, .east: 73, .south: 74]),
        .init(id: "left-ring-aux", label: "left ring aux switch", hand: .left, finger: .ring, thumbLane: nil, directions: [.east: 41, .north: 42, .west: 43, .south: 44]),
        .init(id: "left-middle-aux", label: "left middle aux switch", hand: .left, finger: .middle, thumbLane: nil, directions: [.east: 36, .north: 37, .west: 38, .south: 39]),
        .init(id: "right-middle-aux", label: "right middle aux switch", hand: .right, finger: .middle, thumbLane: nil, directions: [.west: 81, .north: 82, .east: 83, .south: 84]),
        .init(id: "right-ring-aux", label: "right ring aux switch", hand: .right, finger: .ring, thumbLane: nil, directions: [.west: 86, .north: 87, .east: 88, .south: 89]),
        .init(id: "left-pinky", label: "left pinky switch", hand: .left, finger: .pinky, thumbLane: nil, directions: [.east: 31, .north: 32, .west: 33, .south: 34]),
        .init(id: "left-index", label: "left index switch", hand: .left, finger: .index, thumbLane: nil, directions: [.east: 16, .north: 17, .west: 18, .south: 19]),
        .init(id: "right-index", label: "right index switch", hand: .right, finger: .index, thumbLane: nil, directions: [.west: 61, .north: 62, .east: 63, .south: 64]),
        .init(id: "right-pinky", label: "right pinky switch", hand: .right, finger: .pinky, thumbLane: nil, directions: [.west: 76, .north: 77, .east: 78, .south: 79]),
        .init(id: "left-thumb-upper", label: "left thumb upper switch", hand: .left, finger: .thumb, thumbLane: "left thumb lane", directions: [.east: 11, .north: 12, .west: 13, .south: 14]),
        .init(id: "right-thumb-upper", label: "right thumb upper switch", hand: .right, finger: .thumb, thumbLane: "right thumb lane", directions: [.west: 56, .north: 57, .east: 58, .south: 59]),
        .init(id: "left-thumb-lower", label: "left thumb lower switch", hand: .left, finger: .thumb, thumbLane: "left thumb lane", directions: [.east: 6, .north: 7, .west: 8, .south: 9]),
        .init(id: "right-thumb-lower", label: "right thumb lower switch", hand: .right, finger: .thumb, thumbLane: "right thumb lane", directions: [.west: 51, .north: 52, .east: 53, .south: 54])
    ]

    private static let defaultA1Layout = [
        0, 0, 0, 0, 0, 0, 119, 96, 103, 122, 0, 107, 118, 109, 99,
        0, 114, 298, 32, 101, 0, 105, 299, 46, 111, 0, 39, 515, 44, 117,
        0, 513, 514, 550, 540, 0, 40, 61, 41, 47, 0, 91, 512, 93, 297,
        0, 0, 0, 0, 0, 0, 98, 120, 536, 113, 0, 102, 112, 104, 100,
        0, 97, 296, 544, 116, 0, 108, 299, 106, 110, 0, 121, 515, 59, 115,
        0, 517, 518, 551, 542, 0, 336, 338, 335, 337, 0, 63, 45, 127, 553
    ]
}
