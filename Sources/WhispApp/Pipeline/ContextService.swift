import AppKit
import Foundation
import ImageIO
import Vision
import WhispCore

struct AccessibilityContextCapture {
    let snapshot: AccessibilitySnapshot
    let context: ContextInfo?
}

protocol AccessibilityContextProvider: Sendable {
    func capture(frontmostApp: NSRunningApplication?) -> AccessibilityContextCapture
}

protocol VisionContextProvider: Sendable {
    func collect(
        mode: VisionContextMode,
        runID: String,
        preferredWindowOwnerPID: Int32?,
        runDirectory: String?,
        logger: @escaping PipelineEventLogger
    ) async -> VisionContextCollectionResult
}

protocol VisionContextAnalyzer: Sendable {
    var mode: VisionContextMode { get }
    func analyze(
        image: CapturedImage,
        runID: String,
        runDirectory: String?,
        logger: @escaping PipelineEventLogger
    ) async -> ContextInfo?
}

protocol ContextComposer: Sendable {
    func compose(accessibility: ContextInfo?, vision: ContextInfo?) -> ContextInfo?
}

final class SystemAccessibilityContextProvider: AccessibilityContextProvider, @unchecked Sendable {
    func capture(frontmostApp: NSRunningApplication?) -> AccessibilityContextCapture {
        let captured = AccessibilityContextCollector.captureSnapshot(frontmostApp: frontmostApp)
        return AccessibilityContextCapture(snapshot: captured.snapshot, context: captured.context)
    }
}

final class ScreenVisionContextProvider: VisionContextProvider, @unchecked Sendable {
    private let analyzers: [VisionContextMode: any VisionContextAnalyzer]

    init(analyzers: [any VisionContextAnalyzer]? = nil) {
        if let analyzers {
            self.analyzers = Dictionary(uniqueKeysWithValues: analyzers.map { ($0.mode, $0) })
        } else {
            let defaults: [any VisionContextAnalyzer] = [OCRVisionContextAnalyzer()]
            self.analyzers = Dictionary(uniqueKeysWithValues: defaults.map { ($0.mode, $0) })
        }
    }

    func collect(
        mode: VisionContextMode,
        runID: String,
        preferredWindowOwnerPID: Int32?,
        runDirectory: String?,
        logger: @escaping PipelineEventLogger
    ) async -> VisionContextCollectionResult {
        let visionStartedAt = DispatchTime.now()
        let captureStartedAt = DispatchTime.now()
        guard let image = ScreenCapture.captureOptimizedImage(
            maxDimension: 1280,
            jpegQuality: 0.6,
            preferredOwnerPID: preferredWindowOwnerPID
        ) else {
            return VisionContextCollectionResult(
                context: nil,
                captureMs: elapsedMs(since: captureStartedAt),
                analyzeMs: 0,
                totalMs: elapsedMs(since: visionStartedAt),
                imageData: nil,
                imageMimeType: nil,
                imageBytes: 0,
                imageWidth: 0,
                imageHeight: 0,
                mode: mode.rawValue,
                error: "capture_failed"
            )
        }

        let captureMs = elapsedMs(since: captureStartedAt)
        if mode == .saveOnly {
            return VisionContextCollectionResult(
                context: nil,
                captureMs: captureMs,
                analyzeMs: 0,
                totalMs: elapsedMs(since: visionStartedAt),
                imageData: image.data,
                imageMimeType: image.mimeType,
                imageBytes: image.data.count,
                imageWidth: image.width,
                imageHeight: image.height,
                mode: mode.rawValue,
                error: nil
            )
        }

        guard let analyzer = analyzers[mode] else {
            return VisionContextCollectionResult(
                context: nil,
                captureMs: captureMs,
                analyzeMs: 0,
                totalMs: elapsedMs(since: visionStartedAt),
                imageData: image.data,
                imageMimeType: image.mimeType,
                imageBytes: image.data.count,
                imageWidth: image.width,
                imageHeight: image.height,
                mode: mode.rawValue,
                error: "unsupported_mode:\(mode.rawValue)"
            )
        }

        let analyzeStartedAt = DispatchTime.now()
        let context = await analyzer.analyze(
            image: image,
            runID: runID,
            runDirectory: runDirectory,
            logger: logger
        )
        let analyzeMs = elapsedMs(since: analyzeStartedAt)
        let error = (context == nil) ? "context_unavailable" : nil
        return VisionContextCollectionResult(
            context: context,
            captureMs: captureMs,
            analyzeMs: analyzeMs,
            totalMs: elapsedMs(since: visionStartedAt),
            imageData: image.data,
            imageMimeType: image.mimeType,
            imageBytes: image.data.count,
            imageWidth: image.width,
            imageHeight: image.height,
            mode: mode.rawValue,
            error: error
        )
    }
    
    private func elapsedMs(since start: DispatchTime, to end: DispatchTime = .now()) -> Double {
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000
    }
}

struct OCRVisionContextAnalyzer: VisionContextAnalyzer {
    let mode: VisionContextMode = .ocr

    func analyze(
        image: CapturedImage,
        runID _: String,
        runDirectory _: String?,
        logger: @escaping PipelineEventLogger
    ) async -> ContextInfo? {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            logger("vision_collect_failed", [
                "mode": mode.rawValue,
                "error": "ocr_image_decode_failed",
            ])
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ja-JP", "en-US"]

        do {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            let observations = request.results ?? []
            let lines = normalizeOCRLines(observations)
            guard !lines.isEmpty else { return nil }

            let windowText = lines.joined(separator: "\n")
            let summary = String(lines.prefix(2).joined(separator: " / ").prefix(180))
            let terms = extractCandidateTerms(from: lines, limit: 10)
            return ContextInfo(
                windowText: tailExcerpt(from: windowText, maxChars: 1200),
                visionSummary: summary.isEmpty ? nil : summary,
                visionTerms: terms
            )
        } catch {
            logger("vision_collect_failed", [
                "mode": mode.rawValue,
                "error": "ocr_request_failed:\(error.localizedDescription)",
            ])
            return nil
        }
    }

    private func normalizeOCRLines(_ observations: [VNRecognizedTextObservation]) -> [String] {
        var seen: Set<String> = []
        var lines: [String] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                lines.append(String(normalized.prefix(180)))
            }
            if lines.count >= 80 {
                break
            }
        }
        return lines
    }

    private func extractCandidateTerms(from lines: [String], limit: Int) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var seen: Set<String> = []
        var terms: [String] = []
        for line in lines {
            for token in line.components(separatedBy: separators) {
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2, trimmed.count <= 40 else { continue }
                guard trimmed.rangeOfCharacter(from: .letters) != nil else { continue }
                if seen.insert(trimmed).inserted {
                    terms.append(trimmed)
                }
                if terms.count >= limit {
                    return terms
                }
            }
        }
        return terms
    }

    private func tailExcerpt(from text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        let ns = text as NSString
        guard ns.length > 0 else { return "" }
        let length = min(ns.length, maxChars)
        let location = ns.length - length
        return ns.substring(with: NSRange(location: location, length: length))
    }
}

struct DefaultContextComposer: ContextComposer {
    func compose(accessibility: ContextInfo?, vision: ContextInfo?) -> ContextInfo? {
        guard accessibility != nil || vision != nil else {
            return nil
        }

        let accessibilityText = mergeText(
            accessibility?.accessibilityText,
            vision?.accessibilityText
        )
        let windowText = mergeText(
            accessibility?.windowText,
            vision?.windowText
        )

        return ContextInfo(
            accessibilityText: accessibilityText,
            windowText: windowText,
            visionSummary: vision?.visionSummary,
            visionTerms: vision?.visionTerms ?? []
        )
    }

    private func mergeText(_ left: String?, _ right: String?) -> String? {
        let leftTrimmed = left?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightTrimmed = right?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (leftTrimmed?.isEmpty == false ? leftTrimmed : nil, rightTrimmed?.isEmpty == false ? rightTrimmed : nil) {
        case let (.some(lhs), .some(rhs)):
            if lhs == rhs {
                return lhs
            }
            return "\(lhs)\n\(rhs)"
        case let (.some(lhs), nil):
            return lhs
        case let (nil, .some(rhs)):
            return rhs
        case (nil, nil):
            return nil
        }
    }
}

final class ContextService: @unchecked Sendable {
    private let accessibilityProvider: AccessibilityContextProvider
    private let visionProvider: VisionContextProvider
    private let composer: ContextComposer

    init(
        accessibilityProvider: AccessibilityContextProvider,
        visionProvider: VisionContextProvider,
        composer: ContextComposer = DefaultContextComposer()
    ) {
        self.accessibilityProvider = accessibilityProvider
        self.visionProvider = visionProvider
        self.composer = composer
    }

    func captureAccessibility(frontmostApp: NSRunningApplication?) -> AccessibilityContextCapture {
        accessibilityProvider.capture(frontmostApp: frontmostApp)
    }

    func startVisionCollection(
        config: Config,
        runID: String,
        preferredWindowOwnerPID: Int32? = nil,
        runDirectory: String?,
        logger: @escaping PipelineEventLogger
    ) -> Task<VisionContextCollectionResult, Never>? {
        guard config.context.visionEnabled else {
            logger("vision_disabled", [:])
            return nil
        }

        let mode = config.context.visionMode
        let visionProvider = self.visionProvider
        let requestSentAt = Date()
        logger("vision_start", [
            "mode": mode.rawValue,
            "request_sent_at_ms": epochMsString(requestSentAt),
        ])
        return Task {
            await visionProvider.collect(
                mode: mode,
                runID: runID,
                preferredWindowOwnerPID: preferredWindowOwnerPID,
                runDirectory: runDirectory,
                logger: logger
            )
        }
    }

    func resolveVisionIfReady(
        task: Task<VisionContextCollectionResult, Never>?,
        logger: @escaping PipelineEventLogger
    ) async -> VisionContextCollectionResult? {
        guard let task else {
            return nil
        }
        let resolution = await resolveVisionTaskIfReady(task: task)
        guard resolution.ready, let result = resolution.result else {
            logger("vision_not_ready_continue", [:])
            return nil
        }

        logger("vision_done", [
            "image_bytes": String(result.imageBytes),
            "image_wh": "\(result.imageWidth)x\(result.imageHeight)",
            "context_present": String(result.context != nil),
            "mode": result.mode,
            "error": result.error ?? "none",
            "response_received_at_ms": epochMsString(Date()),
        ])
        return result
    }

    func compose(accessibility: ContextInfo?, vision: ContextInfo?) -> ContextInfo? {
        composer.compose(accessibility: accessibility, vision: vision)
    }

    private func epochMsString(_ date: Date) -> String {
        String(format: "%.3f", date.timeIntervalSince1970 * 1000)
    }

    private func resolveVisionTaskIfReady(
        task: Task<VisionContextCollectionResult, Never>
    ) async -> (ready: Bool, result: VisionContextCollectionResult?) {
        let resolution = await TaskReadiness.awaitIfReady(task: task)
        return (resolution.ready, resolution.value)
    }
}
