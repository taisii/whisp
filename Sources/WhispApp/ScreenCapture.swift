import AppKit
import CoreGraphics
import Foundation

enum ScreenCapture {
    static func capturePNG() -> Data? {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            return nil
        }

        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
