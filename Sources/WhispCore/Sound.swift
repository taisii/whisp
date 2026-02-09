import AppKit

public let tinkPath = "/System/Library/Sounds/Tink.aiff"

@discardableResult
public func playTink() -> Bool {
    guard let sound = NSSound(contentsOfFile: tinkPath, byReference: true) else {
        return false
    }
    return sound.play()
}

@discardableResult
public func playCompletionSound() -> Bool {
    playTink()
}

@discardableResult
public func playStartSound() -> Bool {
    playTink()
}
