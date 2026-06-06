import AppKit
import Library

public enum KeyMap {
    private static let baseMappings: [CGKeyCode: String] = [
        0: "a",
        1: "s",
        2: "d",
        3: "f",
        4: "h",
        5: "g",
        6: "z",
        7: "x",
        8: "c",
        9: "v",
        11: "b",
        12: "q",
        13: "w",
        14: "e",
        15: "r",
        16: "y",
        17: "t",
        18: "1",
        19: "2",
        20: "3",
        21: "4",
        22: "6",
        23: "5",
        24: "=",
        25: "9",
        26: "7",
        27: "-",
        28: "8",
        29: "0",
        30: "]",
        31: "o",
        32: "u",
        33: "[",
        34: "i",
        35: "p",
        37: "l",
        38: "j",
        39: "'",
        40: "k",
        41: ";",
        42: "\\",
        43: ",",
        44: "/",
        45: "n",
        46: "m",
        47: ".",
        49: "space"
    ]

    private static let qwertyMap = baseMappings
    private static let colemakMap: [CGKeyCode: String] = {
        var map = baseMappings
        map[0] = "a"
        map[1] = "r"
        map[2] = "s"
        map[3] = "t"
        map[12] = "q"
        map[13] = "w"
        map[14] = "f"
        map[15] = "p"
        map[17] = "g"
        map[31] = "y"
        map[32] = "l"
        map[34] = "u"
        map[35] = "j"
        map[37] = "i"
        map[38] = "n"
        map[40] = "e"
        map[41] = "o"
        return map
    }()

    private static let colemakDHMap: [CGKeyCode: String] = {
        var map = colemakMap
        map[4] = "m"
        map[38] = "n"
        return map
    }()

    public static func token(for keyCode: CGKeyCode, profile: ErgonomicProfile) -> String? {
        switch profile {
        case .ansiQwerty:
            return qwertyMap[keyCode]
        case .ansiColemak:
            return colemakMap[keyCode]
        case .ansiColemakDH:
            return colemakDHMap[keyCode]
        case .cc2A1:
            return qwertyMap[keyCode]
        }
    }

    public static func keyCode(for token: String, profile: ErgonomicProfile) -> CGKeyCode? {
        let lookup = token.lowercased()
        let map: [CGKeyCode: String]
        switch profile {
        case .ansiQwerty, .cc2A1:
            map = qwertyMap
        case .ansiColemak:
            map = colemakMap
        case .ansiColemakDH:
            map = colemakDHMap
        }

        return map.first { $0.value == lookup }?.key
    }

    public static func character(for token: String) -> String? {
        switch token {
        case "space":
            return " "
        case "tab":
            return "\t"
        case "return":
            return "\n"
        default:
            guard token.count == 1 else { return nil }
            return token
        }
    }

    public static let modifierKeyCodes: Set<CGKeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
}
