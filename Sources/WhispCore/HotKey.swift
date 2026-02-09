import Foundation

public struct ParsedHotKey: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum HotKeyParseError: Error, Equatable {
    case invalidFormat(String)
    case unsupportedKey(String)
}

public let carbonShiftModifier: UInt32 = 512
public let carbonCommandModifier: UInt32 = 256
public let carbonOptionModifier: UInt32 = 2048
public let carbonControlModifier: UInt32 = 4096

private let keyCodeMap: [String: UInt32] = [
    "A": 0x00,
    "S": 0x01,
    "D": 0x02,
    "F": 0x03,
    "H": 0x04,
    "G": 0x05,
    "Z": 0x06,
    "X": 0x07,
    "C": 0x08,
    "V": 0x09,
    "B": 0x0B,
    "Q": 0x0C,
    "W": 0x0D,
    "E": 0x0E,
    "R": 0x0F,
    "Y": 0x10,
    "T": 0x11,
    "1": 0x12,
    "2": 0x13,
    "3": 0x14,
    "4": 0x15,
    "6": 0x16,
    "5": 0x17,
    "9": 0x19,
    "7": 0x1A,
    "8": 0x1C,
    "0": 0x1D,
    "O": 0x1F,
    "U": 0x20,
    "I": 0x22,
    "P": 0x23,
    "L": 0x25,
    "J": 0x26,
    "K": 0x28,
    "N": 0x2D,
    "M": 0x2E,
    "ENTER": 0x24,
    "TAB": 0x30,
    "SPACE": 0x31,
    "BACKSPACE": 0x33,
    "ESC": 0x35,
    "ESCAPE": 0x35,
    "F1": 0x7A,
    "F2": 0x78,
    "F3": 0x63,
    "F4": 0x76,
    "F5": 0x60,
    "F6": 0x61,
    "F7": 0x62,
    "F8": 0x64,
    "F9": 0x65,
    "F10": 0x6D,
    "F11": 0x67,
    "F12": 0x6F,
    "UP": 0x7E,
    "DOWN": 0x7D,
    "LEFT": 0x7B,
    "RIGHT": 0x7C,
    "HOME": 0x73,
    "END": 0x77,
    "PAGEUP": 0x74,
    "PAGEDOWN": 0x79,
    "INSERT": 0x72,
    "DELETE": 0x75,
]

public func parseHotKey(_ value: String) throws -> ParsedHotKey {
    let tokens = value.split(separator: "+").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard tokens.count >= 2 else {
        throw HotKeyParseError.invalidFormat(value)
    }

    var modifiers: UInt32 = 0
    for token in tokens.dropLast() {
        switch token.uppercased() {
        case "SHIFT":
            modifiers |= carbonShiftModifier
        case "CONTROL", "CTRL":
            modifiers |= carbonControlModifier
        case "ALT", "OPTION":
            modifiers |= carbonOptionModifier
        case "CMD", "COMMAND", "SUPER":
            modifiers |= carbonCommandModifier
        default:
            throw HotKeyParseError.invalidFormat(value)
        }
    }

    guard modifiers != 0 else {
        throw HotKeyParseError.invalidFormat(value)
    }

    let keyToken = tokens.last!.uppercased()
    guard let keyCode = keyCodeMap[keyToken] else {
        throw HotKeyParseError.unsupportedKey(tokens.last!)
    }

    return ParsedHotKey(keyCode: keyCode, modifiers: modifiers)
}
