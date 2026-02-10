import AppKit
import Foundation

protocol OutputService: Sendable {
    @discardableResult
    func playStartSound() -> Bool

    @discardableResult
    func playCompletionSound() -> Bool

    func sendText(_ text: String) -> Bool
}

struct DirectInputOutputService: OutputService {
    private let soundPath = "/System/Library/Sounds/Tink.aiff"

    @discardableResult
    func playStartSound() -> Bool {
        playTink()
    }

    @discardableResult
    func playCompletionSound() -> Bool {
        playTink()
    }

    func sendText(_ text: String) -> Bool {
        DirectInput.sendText(text)
    }

    @discardableResult
    private func playTink() -> Bool {
        guard let sound = NSSound(contentsOfFile: soundPath, byReference: true) else {
            return false
        }
        return sound.play()
    }
}
