import AppKit
import ApplicationServices
import Foundation

enum DirectInput {
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission(prompt: Bool = true) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    @discardableResult
    static func sendText(_ text: String) -> Bool {
        guard requestAccessibilityPermission(prompt: true) else {
            return false
        }

        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else {
            return true
        }

        let chunkSize = 20
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        var index = 0
        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            let chunk = Array(utf16[index..<end])

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                return false
            }

            chunk.withUnsafeBufferPointer { ptr in
                guard let baseAddress = ptr.baseAddress else {
                    return
                }
                keyDown.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: baseAddress)
                keyUp.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: baseAddress)
            }

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            index = end
        }

        return true
    }

    static func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
