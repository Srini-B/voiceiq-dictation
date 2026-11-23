import CoreGraphics
import Foundation

public struct KeyShortcut: Codable, Equatable, Sendable {
    public enum Modifier: String, Codable, CaseIterable, Hashable, Sendable {
        case command
        case option
        case control
        case shift

        fileprivate var genericMask: UInt64 {
            switch self {
            case .command: return 0x10_0000 // CGEventFlags.maskCommand
            case .option: return 0x08_0000 // CGEventFlags.maskAlternate
            case .control: return 0x04_0000 // CGEventFlags.maskControl
            case .shift: return 0x02_0000 // CGEventFlags.maskShift
            }
        }

        fileprivate var leftMask: UInt64 {
            switch self {
            case .command: return 0x0008
            case .option: return 0x0020
            case .control: return 0x0001
            case .shift: return 0x0002
            }
        }

        fileprivate var rightMask: UInt64 {
            switch self {
            case .command: return 0x0010
            case .option: return 0x0040
            case .control: return 0x2000
            case .shift: return 0x0004
            }
        }

        fileprivate var symbol: String {
            switch self {
            case .command: return "⌘"
            case .option: return "⌥"
            case .control: return "⌃"
            case .shift: return "⇧"
            }
        }
    }

    public enum Side: String, Codable, CaseIterable, Sendable {
        case either
        case left
        case right

        public var displayName: String { rawValue.capitalized }
    }

    public let keyCode: UInt16
    public let modifiers: Set<Modifier>
    public let side: Side

    public init(keyCode: UInt16, modifiers: Set<Modifier>, side: Side = .either) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.side = side
    }

    /// F13–F19 have no letter to type, so they work alone, without a
    /// modifier. Stream Deck buttons and Karabiner remaps send them
    /// (FluidVoice accepts them the same way, altic-dev/FluidVoice).
    public static let standaloneKeyCodes: Set<UInt16> = [105, 107, 113, 106, 64, 79, 80]

    public var displayString: String {
        let prefix = side == .either ? "" : "\(side.displayName) "
        let ordered: [Modifier] = [.control, .option, .shift, .command]
        let modifierSymbols = ordered.filter(modifiers.contains).map(\.symbol).joined()
        return prefix + modifierSymbols + Self.keyLabel(for: keyCode)
    }

    #if os(macOS)
    public func matches(eventFlags flags: CGEventFlags, keyCode: UInt16) -> Bool {
        matches(rawFlags: flags.rawValue, keyCode: keyCode)
    }
    #endif

    public func matches(rawFlags: UInt64, keyCode: UInt16) -> Bool {
        guard keyCode == self.keyCode else { return false }

        let active = Set(Modifier.allCases.filter { rawFlags & $0.genericMask != 0 })
        guard active == modifiers else { return false }

        switch side {
        case .either:
            return true
        case .left:
            return modifiers.allSatisfy {
                rawFlags & $0.leftMask != 0 && rawFlags & $0.rightMask == 0
            }
        case .right:
            return modifiers.allSatisfy {
                rawFlags & $0.rightMask != 0 && rawFlags & $0.leftMask == 0
            }
        }
    }

    private static func keyLabel(for keyCode: UInt16) -> String {
        let labels: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space", 50: "`", 51: "⌫",
            53: "Esc", 65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/", 76: "⌅",
            78: "-", 81: "=", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4",
            87: "5", 88: "6", 89: "7", 91: "8", 92: "9", 96: "F5", 97: "F6",
            98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10",
            111: "F12", 115: "Home", 116: "Page Up", 117: "⌦", 118: "F4",
            119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←",
            124: "→", 125: "↓", 126: "↑", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19",
        ]
        return labels[keyCode] ?? "Key \(keyCode)"
    }
}
