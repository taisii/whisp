import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

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
    ) async -> CapturedImage? {
        guard let image = await captureActiveWindowImage(
            maxDimension: maxDimension,
            preferredOwnerPID: preferredOwnerPID
        ) else {
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

    private static func captureActiveWindowImage(
        maxDimension: Int,
        preferredOwnerPID: Int32?
    ) async -> CGImage? {
        do {
            guard let window = try await frontmostWindow(preferredOwnerPID: preferredOwnerPID) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = optimizedStreamConfiguration(for: filter, maxDimension: maxDimension)
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            return nil
        }
    }

    private static func frontmostWindow(preferredOwnerPID: Int32?) async throws -> SCWindow? {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let targetPID: Int32?
        if let preferredOwnerPID {
            targetPID = preferredOwnerPID
        } else {
            targetPID = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            }
        }

        if let targetPID {
            let matching = shareableContent.windows.filter { isCapturableWindow($0, expectedOwnerPID: targetPID) }
            return matching.first(where: { $0.isActive }) ?? matching.first
        }

        let windows = shareableContent.windows.filter { isCapturableWindow($0, expectedOwnerPID: nil) }
        return windows.first(where: { $0.isActive }) ?? windows.first
    }

    private static func optimizedStreamConfiguration(
        for filter: SCContentFilter,
        maxDimension: Int
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.scalesToFit = true
        config.ignoreShadowsSingleWindow = true

        let rect = filter.contentRect
        let pixelScale = max(CGFloat(filter.pointPixelScale), 1)
        let sourceWidth = max(1, Int((rect.width * pixelScale).rounded()))
        let sourceHeight = max(1, Int((rect.height * pixelScale).rounded()))
        let longest = max(sourceWidth, sourceHeight)
        let scale = min(1.0, CGFloat(maxDimension) / CGFloat(max(longest, 1)))
        let targetWidth = max(1, Int((CGFloat(sourceWidth) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(sourceHeight) * scale).rounded()))

        config.width = targetWidth
        config.height = targetHeight
        return config
    }

    private static func isCapturableWindow(_ window: SCWindow, expectedOwnerPID: Int32?) -> Bool {
        if let expectedOwnerPID, ownerPID(from: window) != expectedOwnerPID {
            return false
        }
        guard window.windowLayer == 0 else {
            return false
        }
        guard window.isOnScreen else {
            return false
        }
        return window.frame.width >= 120 && window.frame.height >= 120
    }

    private static func ownerPID(from window: SCWindow) -> Int32? {
        window.owningApplication.map { Int32($0.processID) }
    }
}
