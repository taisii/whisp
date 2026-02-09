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
    static func captureOptimizedImage(maxDimension: Int = 1280, jpegQuality: CGFloat = 0.6) -> CapturedImage? {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
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
}
