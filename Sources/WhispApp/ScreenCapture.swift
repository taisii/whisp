import AppKit
import CoreGraphics
import Foundation

struct CapturedImage {
    let data: Data
    let mimeType: String
    let width: Int
    let height: Int
}

enum ScreenCapture {
    static func captureOptimizedImage(
        maxDimension: Int = 1280,
        jpegQuality: CGFloat = 0.6,
        preferredOwnerPID: Int32? = nil
    ) -> CapturedImage? {
        guard let image = captureActiveWindowImage(preferredOwnerPID: preferredOwnerPID) else {
            return nil
        }

        let sourceWidth = image.width
        let sourceHeight = image.height
        let longest = max(sourceWidth, sourceHeight)
        let scale = min(1.0, CGFloat(maxDimension) / CGFloat(max(longest, 1)))
        let targetWidth = max(1, Int((CGFloat(sourceWidth) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(sourceHeight) * scale).rounded()))

        let finalImage: CGImage
        if targetWidth == sourceWidth && targetHeight == sourceHeight {
            finalImage = image
        } else {
            guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: nil,
                    width: targetWidth,
                    height: targetHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                return nil
            }

            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let scaled = context.makeImage() else {
                return nil
            }
            finalImage = scaled
        }

        let rep = NSBitmapImageRep(cgImage: finalImage)
        let properties: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: jpegQuality]
        guard let jpeg = rep.representation(using: .jpeg, properties: properties) else {
            return nil
        }

        return CapturedImage(
            data: jpeg,
            mimeType: "image/jpeg",
            width: targetWidth,
            height: targetHeight
        )
    }

    private static func captureActiveWindowImage(preferredOwnerPID: Int32?) -> CGImage? {
        guard let windowID = frontmostWindowID(preferredOwnerPID: preferredOwnerPID) else {
            return nil
        }
        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )
    }

    private static func frontmostWindowID(preferredOwnerPID: Int32?) -> CGWindowID? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let targetPID = preferredOwnerPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let targetPID {
            if let matched = windowList.first(where: { info in isCapturableWindow(info, expectedOwnerPID: targetPID) }) {
                return windowNumber(from: matched)
            }
            return nil
        }

        guard let first = windowList.first(where: { isCapturableWindow($0, expectedOwnerPID: nil) }) else {
            return nil
        }
        return windowNumber(from: first)
    }

    private static func isCapturableWindow(_ info: [String: Any], expectedOwnerPID: Int32?) -> Bool {
        if let expectedOwnerPID, ownerPID(from: info) != expectedOwnerPID {
            return false
        }
        guard let layerNumber = info[kCGWindowLayer as String] as? NSNumber, layerNumber.intValue == 0 else {
            return false
        }
        if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0.01 {
            return false
        }
        guard let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo)
        else {
            return false
        }
        return bounds.width >= 120 && bounds.height >= 120
    }

    private static func ownerPID(from info: [String: Any]) -> Int32? {
        (info[kCGWindowOwnerPID as String] as? NSNumber).map { Int32(truncating: $0) }
    }

    private static func windowNumber(from info: [String: Any]) -> CGWindowID? {
        (info[kCGWindowNumber as String] as? NSNumber).map { CGWindowID(truncating: $0) }
    }
}
