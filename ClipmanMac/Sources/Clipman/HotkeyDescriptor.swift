import Foundation
import Carbon
import AppKit

struct HotkeyDescriptor: Codable, Equatable, Hashable, CustomStringConvertible {
    struct Modifiers: OptionSet, Codable, Equatable, Hashable {
        let rawValue: UInt32

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let command = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)

        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            rawValue = try container.decode(UInt32.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        var carbonFlags: UInt32 {
            var flags: UInt32 = 0
            if contains(.control) { flags |= UInt32(controlKey) }
            if contains(.option) { flags |= UInt32(optionKey) }
            if contains(.command) { flags |= UInt32(cmdKey) }
            if contains(.shift) { flags |= UInt32(shiftKey) }
            return flags
        }

        var count: Int {
            var total = 0
            if contains(.control) { total += 1 }
            if contains(.option) { total += 1 }
            if contains(.command) { total += 1 }
            if contains(.shift) { total += 1 }
            return total
        }

        init(eventModifierFlags: NSEvent.ModifierFlags) {
            var value: Modifiers = []
            if eventModifierFlags.contains(.control) { value.insert(.control) }
            if eventModifierFlags.contains(.option) { value.insert(.option) }
            if eventModifierFlags.contains(.command) { value.insert(.command) }
            if eventModifierFlags.contains(.shift) { value.insert(.shift) }
            self = value
        }
    }

    var keyCode: UInt32
    var modifiers: Modifiers

    var isValid: Bool {
        guard Self.isAllowedKeyCode(keyCode) else { return false }
        let modifierCount = modifiers.count
        if Self.isFunctionKey(keyCode) {
            return modifierCount >= 1
        }
        return modifierCount >= 2
    }

    var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Command") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined(separator: "+")
    }

    var layoutFallbacks: [HotkeyDescriptor] {
        switch Int(keyCode) {
        case kVK_ISO_Section:
            [HotkeyDescriptor(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: modifiers)]
        case kVK_ANSI_Backslash:
            [HotkeyDescriptor(keyCode: UInt32(kVK_ISO_Section), modifiers: modifiers)]
        default:
            []
        }
    }

    static func parse(_ text: String) -> HotkeyDescriptor? {
        let pieces = text
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return nil }

        var modifiers: Modifiers = []
        var keyCode: UInt32?
        for piece in pieces {
            switch piece {
            case "control", "ctrl": modifiers.insert(.control)
            case "option", "alt": modifiers.insert(.option)
            case "command", "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            default:
                keyCode = Self.keyCode(for: piece)
            }
        }

        guard let keyCode, !modifiers.isEmpty else { return nil }
        return HotkeyDescriptor(keyCode: keyCode, modifiers: modifiers)
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_Backslash: "\\"
        case kVK_ANSI_Grave: "Grave"
        case kVK_ISO_Section: "ISO `"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_Escape: "Escape"
        default: "Key\(keyCode)"
        }
    }

    static func isAllowedKeyCode(_ keyCode: UInt32) -> Bool {
        let allowed: Set<UInt32> = [
            UInt32(kVK_ANSI_A), UInt32(kVK_ANSI_B), UInt32(kVK_ANSI_C), UInt32(kVK_ANSI_D),
            UInt32(kVK_ANSI_E), UInt32(kVK_ANSI_F), UInt32(kVK_ANSI_G), UInt32(kVK_ANSI_H),
            UInt32(kVK_ANSI_I), UInt32(kVK_ANSI_J), UInt32(kVK_ANSI_K), UInt32(kVK_ANSI_L),
            UInt32(kVK_ANSI_M), UInt32(kVK_ANSI_N), UInt32(kVK_ANSI_O), UInt32(kVK_ANSI_P),
            UInt32(kVK_ANSI_Q), UInt32(kVK_ANSI_R), UInt32(kVK_ANSI_S), UInt32(kVK_ANSI_T),
            UInt32(kVK_ANSI_U), UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_W), UInt32(kVK_ANSI_X),
            UInt32(kVK_ANSI_Y), UInt32(kVK_ANSI_Z),
            UInt32(kVK_ANSI_0), UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6), UInt32(kVK_ANSI_7),
            UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9),
            UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
            UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
            UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
            UInt32(kVK_ANSI_Backslash), UInt32(kVK_ANSI_Grave), UInt32(kVK_ISO_Section)
        ]
        return allowed.contains(keyCode)
    }

    private static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
             kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12:
            true
        default:
            false
        }
    }

    private static func keyCode(for name: String) -> UInt32? {
        if name == "\\" || name == "backslash" { return UInt32(kVK_ANSI_Backslash) }
        if name == "`" || name == "grave" { return UInt32(kVK_ANSI_Grave) }
        if name == "#" || name == "hash" || name == "iso section" || name == "section" || name == "iso `" { return UInt32(kVK_ISO_Section) }
        if name == "space" { return nil }
        if name == "return" || name == "enter" { return nil }
        let digits: [String: Int] = [
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9
        ]
        if let keyCode = digits[name] {
            return UInt32(keyCode)
        }
        let functionKeys: [String: Int] = [
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
            "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
            "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12
        ]
        if let keyCode = functionKeys[name] {
            return UInt32(keyCode)
        }
        let letters: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z
        ]
        return letters[name].map(UInt32.init)
    }
}
