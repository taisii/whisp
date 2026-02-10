import AppKit
import Foundation
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
        model: LLMModel,
        apiKey: String,
        runID: String,
        runDirectory: String?,
        logger: @escaping PipelineEventLogger
    ) async -> VisionContextCollectionResult
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
    private let postProcessor: PostProcessorService

    init(postProcessor: PostProcessorService) {
        self.postProcessor = postProcessor
    }

    func collect(
        model: LLMModel,
        apiKey: String,
        runID: String,
        runDirectory: String?,
        logger: @escaping PipelineEventLogger
    ) async -> VisionContextCollectionResult {
        let visionStartedAt = DispatchTime.now()
        let captureStartedAt = DispatchTime.now()
        guard let image = ScreenCapture.captureOptimizedImage(maxDimension: 1280, jpegQuality: 0.6) else {
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
                error: "capture_failed"
            )
        }

        let captureMs = elapsedMs(since: captureStartedAt)
        do {
            let analyzeStartedAt = DispatchTime.now()
            let context = try await postProcessor.analyzeVisionContext(
                model: model,
                apiKey: apiKey,
                imageData: image.data,
                mimeType: image.mimeType,
                debugRunID: runID,
                debugRunDirectory: runDirectory
            )
            return VisionContextCollectionResult(
                context: context,
                captureMs: captureMs,
                analyzeMs: elapsedMs(since: analyzeStartedAt),
                totalMs: elapsedMs(since: visionStartedAt),
                imageData: image.data,
                imageMimeType: image.mimeType,
                imageBytes: image.data.count,
                imageWidth: image.width,
                imageHeight: image.height,
                error: nil
            )
        } catch {
            logger("vision_collect_failed", ["error": error.localizedDescription])
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
                error: error.localizedDescription
            )
        }
    }

    private func elapsedMs(since start: DispatchTime, to end: DispatchTime = .now()) -> Double {
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000
    }
}

struct DefaultContextComposer: ContextComposer {
    func compose(accessibility: ContextInfo?, vision: ContextInfo?) -> ContextInfo? {
        guard accessibility != nil || vision != nil else {
            return nil
        }
        return ContextInfo(
            accessibilityText: accessibility?.accessibilityText ?? vision?.accessibilityText,
            visionSummary: vision?.visionSummary,
            visionTerms: vision?.visionTerms ?? []
        )
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
        runDirectory: String?,
        llmAPIKey: String?,
        logger: @escaping PipelineEventLogger
    ) -> Task<VisionContextCollectionResult, Never>? {
        guard config.context.visionEnabled else {
            logger("vision_disabled", [:])
            return nil
        }
        guard let llmAPIKey, !llmAPIKey.isEmpty else {
            logger("vision_skipped_missing_key", [:])
            return nil
        }

        let model = config.llmModel
        let visionProvider = self.visionProvider
        logger("vision_start", ["model": model.rawValue])
        return Task {
            await visionProvider.collect(
                model: model,
                apiKey: llmAPIKey,
                runID: runID,
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
        let waitStartedAt = DispatchTime.now()
        let maybeResult = await withTaskGroup(of: VisionContextCollectionResult?.self, returning: VisionContextCollectionResult?.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let result = maybeResult else {
            task.cancel()
            logger("vision_skipped_not_ready", [
                "wait_ms": msString(elapsedMs(since: waitStartedAt)),
            ])
            return nil
        }

        logger("vision_done", [
            "wait_ms": msString(elapsedMs(since: waitStartedAt)),
            "capture_ms": msString(result.captureMs),
            "analyze_ms": msString(result.analyzeMs),
            "total_ms": msString(result.totalMs),
            "image_bytes": String(result.imageBytes),
            "image_wh": "\(result.imageWidth)x\(result.imageHeight)",
            "context_present": String(result.context != nil),
            "error": result.error ?? "none",
        ])
        return result
    }

    func compose(accessibility: ContextInfo?, vision: ContextInfo?) -> ContextInfo? {
        composer.compose(accessibility: accessibility, vision: vision)
    }

    private func elapsedMs(since start: DispatchTime, to end: DispatchTime = .now()) -> Double {
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000
    }

    private func msString(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
