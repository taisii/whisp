import AppKit
import XCTest
import WhispCore
@testable import WhispApp

final class ContextServiceTests: XCTestCase {
    func testResolveVisionIfReadyReturnsNilWhenTaskNotReady() async {
        let service = ContextService(
            accessibilityProvider: StubAccessibilityProvider(),
            visionProvider: StubVisionProvider()
        )
        let task = Task<VisionContextCollectionResult, Never> {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return VisionContextCollectionResult(
                context: ContextInfo(visionSummary: "summary", visionTerms: ["term"]),
                captureMs: 10,
                analyzeMs: 20,
                totalMs: 30,
                imageData: Data([0x01, 0x02, 0x03]),
                imageMimeType: "image/jpeg",
                imageBytes: 3,
                imageWidth: 100,
                imageHeight: 80,
                mode: VisionContextMode.llm.rawValue,
                error: nil
            )
        }

        let resolved = await service.resolveVisionIfReady(task: task) { _, _ in }
        XCTAssertNil(resolved)
        XCTAssertFalse(task.isCancelled)
    }

    func testResolveVisionIfReadyReturnsResultWhenTaskAlreadyDone() async {
        let service = ContextService(
            accessibilityProvider: StubAccessibilityProvider(),
            visionProvider: StubVisionProvider()
        )
        let task = Task<VisionContextCollectionResult, Never> {
            VisionContextCollectionResult(
                context: ContextInfo(visionSummary: "summary", visionTerms: ["term"]),
                captureMs: 10,
                analyzeMs: 20,
                totalMs: 30,
                imageData: Data([0x01, 0x02, 0x03]),
                imageMimeType: "image/jpeg",
                imageBytes: 3,
                imageWidth: 100,
                imageHeight: 80,
                mode: VisionContextMode.llm.rawValue,
                error: nil
            )
        }

        try? await Task.sleep(nanoseconds: 5_000_000)
        let resolved = await service.resolveVisionIfReady(task: task) { _, _ in }
        XCTAssertEqual(resolved?.imageBytes, 3)
        XCTAssertEqual(resolved?.context?.visionSummary, "summary")
    }

    func testStartVisionCollectionDoesNotRequireAPIKey() async {
        let service = ContextService(
            accessibilityProvider: StubAccessibilityProvider(),
            visionProvider: StubVisionProvider()
        )

        var llmConfig = Config()
        llmConfig.context.visionEnabled = true
        llmConfig.context.visionMode = .llm
        let llmTask = service.startVisionCollection(
            config: llmConfig,
            runID: "run-llm",
            runDirectory: nil,
            logger: { _, _ in }
        )
        XCTAssertNotNil(llmTask)
        _ = await llmTask?.value

        var ocrConfig = Config()
        ocrConfig.context.visionEnabled = true
        ocrConfig.context.visionMode = .ocr
        let ocrTask = service.startVisionCollection(
            config: ocrConfig,
            runID: "run-ocr",
            runDirectory: nil,
            logger: { _, _ in }
        )
        XCTAssertNotNil(ocrTask)
        _ = await ocrTask?.value
    }
}

private struct StubAccessibilityProvider: AccessibilityContextProvider {
    func capture(frontmostApp: NSRunningApplication?) -> AccessibilityContextCapture {
        let snapshot = AccessibilitySnapshot(
            capturedAt: "2026-02-10T00:00:00Z",
            trusted: true,
            appName: nil,
            bundleID: nil,
            processID: nil,
            windowTitle: nil,
            focusedElement: nil,
            error: nil
        )
        return AccessibilityContextCapture(snapshot: snapshot, context: nil)
    }
}

private struct StubVisionProvider: VisionContextProvider {
    func collect(
        mode _: VisionContextMode,
        model: LLMModel,
        runID: String,
        preferredWindowOwnerPID: Int32?,
        runDirectory: String?,
        logger: @escaping PipelineEventLogger
    ) async -> VisionContextCollectionResult {
        VisionContextCollectionResult(
            context: nil,
            captureMs: 0,
            analyzeMs: 0,
            totalMs: 0,
            imageData: nil,
            imageMimeType: nil,
            imageBytes: 0,
            imageWidth: 0,
            imageHeight: 0,
            mode: VisionContextMode.llm.rawValue,
            error: nil
        )
    }
}
