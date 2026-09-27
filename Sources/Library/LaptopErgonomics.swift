import Foundation

/// Which finger presses each key on a laptop (touch typing on ANSI QWERTY),
/// and how comfortable it is to press a set of keys at the same moment.
///
/// Master Forge chords are laid out for its own switches, so on a laptop
/// some land on one finger (`w+x`, `l+o`) and can't be pressed together at
/// all, while others need a claw across three rows.
public enum LaptopErgonomics {
    struct Key {
        /// 0 left, 1 right.
        let hand: Int
        /// 0 pinky … 3 index.
        let finger: Int
        /// 0 top, 1 home, 2 bottom.
        let row: Int
        let column: Int
    }

    static let keys: [Character: Key] = {
        var result: [Character: Key] = [:]
        for (row, letters) in ["qwertyuiop", "asdfghjkl;", "zxcvbnm,./"].enumerated() {
            for (column, character) in letters.enumerated() {
                let hand = column <= 4 ? 0 : 1
                let finger: Int
                switch column {
                case 0, 9: finger = 0
                case 1, 8: finger = 1
                case 2, 7: finger = 2
                default: finger = 3
                }
                result[character] = Key(hand: hand, finger: finger, row: row, column: column)
            }
        }
        result["'"] = Key(hand: 1, finger: 0, row: 1, column: 10)
        return result
    }()

    /// Effort to press these keys together; nil when two share a finger or
    /// a key isn't a letter key. Home row keys are free, reaching up or down
    /// and using the pinky or the center columns cost a little, and a hand
    /// spanning top and bottom rows at once costs more.
    public static func cost<S: Sequence>(_ characters: S) -> Double? where S.Element == Character {
        let found = characters.map { keys[Character($0.lowercased())] }
        guard (2...4).contains(found.count), !found.contains(where: { $0 == nil }) else { return nil }
        let pressed = found.compactMap { $0 }
        var fingers: Set<Int> = []
        var cost = 0.0
        for key in pressed {
            guard fingers.insert(key.hand * 4 + key.finger).inserted else { return nil }
            cost += key.row == 1 ? 0 : (key.row == 0 ? 0.8 : 1.2)
            if key.finger == 0 { cost += 0.8 }
            if key.column == 4 || key.column == 5 { cost += 0.4 }
        }
        for (index, first) in pressed.enumerated() {
            for second in pressed[(index + 1)...] where first.hand == second.hand && abs(first.row - second.row) == 2 {
                cost += 0.6
            }
        }
        switch pressed.count {
        case 3: cost += 0.5
        case 4: cost += 1.5
        default: break
        }
        return cost
    }

    /// The most effort still worth pressing, by number of keys.
    public static func limit(keys: Int) -> Double {
        switch keys {
        case ...2: return 3.0
        case 3: return 3.8
        default: return 4.8
        }
    }

    public static func isComfortable<S: Collection>(_ characters: S) -> Bool where S.Element == Character {
        guard let cost = cost(characters) else { return false }
        return cost <= limit(keys: characters.count)
    }
}
