import Foundation

public struct ShortcutInput: Equatable, Sendable {
    public var key: String
    public var metaKey: Bool
    public var ctrlKey: Bool
    public var altKey: Bool
    public var shiftKey: Bool

    public init(key: String, metaKey: Bool = false, ctrlKey: Bool = false, altKey: Bool = false, shiftKey: Bool = false) {
        self.key = key
        self.metaKey = metaKey
        self.ctrlKey = ctrlKey
        self.altKey = altKey
        self.shiftKey = shiftKey
    }
}

private let modifierKeys: Set<String> = ["Shift", "Control", "Alt", "Meta"]
private let specialKeyMap: [String: String] = [
    " ": "Space",
    "Enter": "Enter",
    "Tab": "Tab",
    "Backspace": "Backspace",
    "Delete": "Delete",
    "Escape": "Esc",
    "ArrowUp": "Up",
    "ArrowDown": "Down",
    "ArrowLeft": "Left",
    "ArrowRight": "Right",
    "Home": "Home",
    "End": "End",
    "PageUp": "PageUp",
    "PageDown": "PageDown",
    "Insert": "Insert",
]

private func isFunctionKey(_ key: String) -> Bool {
    let upper = key.uppercased()
    guard upper.hasPrefix("F") else { return false }
    guard let number = Int(upper.dropFirst()) else { return false }
    return (1...12).contains(number)
}

private func normalizeKey(_ key: String) -> String? {
    if modifierKeys.contains(key) {
        return nil
    }
    if let mapped = specialKeyMap[key] {
        return mapped
    }
    if isFunctionKey(key) {
        return key.uppercased()
    }
    if key.count == 1 {
        return key.uppercased()
    }
    return nil
}

public func buildShortcutString(_ input: ShortcutInput) -> String? {
    guard let mainKey = normalizeKey(input.key) else {
        return nil
    }

    var modifiers: [String] = []
    if input.metaKey { modifiers.append("Cmd") }
    if input.ctrlKey { modifiers.append("Ctrl") }
    if input.altKey { modifiers.append("Alt") }
    if input.shiftKey { modifiers.append("Shift") }

    guard !modifiers.isEmpty else {
        return nil
    }

    return (modifiers + [mainKey]).joined(separator: "+")
}

private let displayMap: [String: String] = [
    "Cmd": "⌘",
    "Command": "⌘",
    "CmdOrCtrl": "⌘/⌃",
    "CommandOrControl": "⌘/⌃",
    "Ctrl": "⌃",
    "Control": "⌃",
    "Alt": "⌥",
    "Option": "⌥",
    "Shift": "⇧",
]

public func formatShortcutDisplay(_ shortcut: String) -> String {
    if shortcut.isEmpty {
        return "-"
    }

    let parts = shortcut.split(separator: "+").map(String.init)
    return parts
        .map { displayMap[$0] ?? $0.uppercased() }
        .joined(separator: " ")
}
