import AppKit
import Foundation
import XCTest
import WhispCore
@testable import WhispApp

@MainActor
final class PipelineRunnerTests: XCTestCase {
    func testRunSkipsWhenAudioIsEmpty() async throws {
        let harness = try makeHarness(
            sttTranscript: "ignored",
            postProcessText: "ignored",
            audioTranscribeText: "ignored",
            outputSuccess: true
        )
        let input = makeInput(config: harness.config, pcmData: Data())

        let outcome = await run(harness: harness, input: input)
        guard case let .skipped(reason, _, _) = outcome else {
            return XCTFail("expected skipped")
        }
        XCTAssertEqual(reason, .emptyAudio)
    }

    func testRunSkipsWhenSTTIsEmpty() async throws {
        let harness = try makeHarness(
            sttTranscript: "  ",
            postProcessText: "ignored",
            audioTranscribeText: "ignored",
            outputSuccess: true
        )
        let input = makeInput(config: harness.config, pcmData: Data(repeating: 1, count: 3200))

        let outcome = await run(harness: harness, input: input)
        guard case let .skipped(reason, _, _) = outcome else {
            return XCTFail("expected skipped")
        }
        XCTAssertEqual(reason, .emptySTT)
    }

    func testRunSkipsWhenPostProcessOutputIsEmpty() async throws {
        let harness = try makeHarness(
            sttTranscript: "hello",
            postProcessText: " ",
            audioTranscribeText: "ignored",
            outputSuccess: true
        )
        let input = makeInput(config: harness.config, pcmData: Data(repeating: 1, count: 3200))

        let outcome = await run(harness: harness, input: input)
        guard case let .skipped(reason, _, _) = outcome else {
            return XCTFail("expected skipped")
        }
        XCTAssertEqual(reason, .emptyOutput)
    }

    func testRunDirectAudioPathCompletes() async throws {
        var config = baseConfig()
        config.llmModel = .gemini25FlashLiteAudio
        let harness = try makeHarness(
            config: config,
            sttTranscript: "unused",
            postProcessText: "unused",
            audioTranscribeText: "direct-audio-text",
            outputSuccess: true
        )
        let input = makeInput(config: harness.config, pcmData: Data(repeating: 1, count: 3200))

        let outcome = await run(harness: harness, input: input)
        guard case let .completed(sttText, outputText, directInputSucceeded) = outcome else {
            return XCTFail("expected completed")
        }
        XCTAssertEqual(sttText, "direct-audio-text")
        XCTAssertEqual(outputText, "direct-audio-text")
        XCTAssertTrue(directInputSucceeded)
    }

    func testRunCompletesWithOutputErrorWhenDirectInputFails() async throws {
        let harness = try makeHarness(
            sttTranscript: "hello",
            postProcessText: "processed",
            audioTranscribeText: "unused",
            outputSuccess: false
        )
        let input = makeInput(config: harness.config, pcmData: Data(repeating: 1, count: 3200))
        var warning: String?

        let outcome = await run(harness: harness, input: input, notifyWarning: { warning = $0 })
        guard case let .completed(_, outputText, directInputSucceeded) = outcome else {
            return XCTFail("expected completed")
        }
        XCTAssertEqual(outputText, "processed")
        XCTAssertFalse(directInputSucceeded)
        XCTAssertNotNil(warning)
    }

    func testRunFailsWhenSTTThrows() async throws {
        let harness = try makeHarness(
            sttTranscript: nil,
            postProcessText: "unused",
            audioTranscribeText: "unused",
            outputSuccess: true
        )
        let input = makeInput(config: harness.config, pcmData: Data(repeating: 1, count: 3200))

        let outcome = await run(harness: harness, input: input)
        guard case let .failed(message, _, _) = outcome else {
            return XCTFail("expected failed")
        }
        XCTAssertTrue(message.contains("処理に失敗"))
    }

    private func makeInput(config: Config, pcmData: Data) -> PipelineRunInput {
        PipelineRunInput(
            result: RecordingResult(sampleRate: 16_000, pcmData: pcmData),
            config: config,
            run: PipelineRun(
                id: "run-test",
                startedAtDate: Date(),
                appNameAtStart: "Xcode",
                appPIDAtStart: nil,
                accessibilitySummarySourceAtStart: nil,
                accessibilitySummaryTask: nil,
                recordingMode: "toggle",
                model: config.llmModel.rawValue,
                sttProvider: config.sttProvider.rawValue,
                sttStreaming: false,
                visionEnabled: false,
                accessibilitySummaryStarted: false
            ),
            artifacts: DebugRunArtifacts(captureID: nil, runDirectory: nil, accessibilityContext: nil),
            sttStreamingSession: nil,
            accessibilitySummarySourceAtStop: nil
        )
    }

    private func run(
        harness: (runner: PipelineRunner, config: Config),
        input: PipelineRunInput,
        notifyWarning: @escaping (String) -> Void = { _ in }
    ) async -> PipelineOutcome {
        await harness.runner.run(context: RunContext(
            input: input,
            transition: { _ in },
            notifyWarning: notifyWarning
        ))
    }

    private func makeHarness(
        config: Config = baseConfig(),
        sttTranscript: String?,
        postProcessText: String,
        audioTranscribeText: String,
        outputSuccess: Bool
    ) throws -> (
        runner: PipelineRunner,
        config: Config
    ) {
        let postProcessor = PostProcessorService(providers: [
            FakeLLMProvider(postProcessText: postProcessText, audioTranscribeText: audioTranscribeText),
        ])
        let sttService = FakeSTTService(transcript: sttTranscript)
        let contextService = ContextService(
            accessibilityProvider: FakeAccessibilityProvider(),
            visionProvider: FakeVisionProvider()
        )
        let outputService = FakeOutputService(sendTextResult: outputSuccess)
        let usageStorePath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("usage.json", isDirectory: false)
        let usageStore = try UsageStore(path: usageStorePath)
        let runner = PipelineRunner(
            usageStore: usageStore,
            postProcessor: postProcessor,
            sttService: sttService,
            contextService: contextService,
            outputService: outputService,
            debugCaptureService: DebugCaptureService()
        )
        return (runner, config)
    }

    private static func baseConfig() -> Config {
        Config(
            apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa"),
            shortcut: "Cmd+J",
            inputLanguage: "ja",
            recordingMode: .toggle,
            sttProvider: .deepgram,
            appPromptRules: [],
            llmModel: .gemini25FlashLite,
            context: ContextConfig(visionEnabled: false, visionMode: .saveOnly)
        )
    }

    private func baseConfig() -> Config { Self.baseConfig() }
}

private struct FakeLLMProvider: LLMAPIProvider, @unchecked Sendable {
    let postProcessText: String
    let audioTranscribeText: String

    func supports(model _: LLMModel) -> Bool { true }

    func postProcess(
        apiKey _: String,
        model _: LLMModel,
        prompt _: String
    ) async throws -> PostProcessResult {
        PostProcessResult(text: postProcessText, usage: nil)
    }

    func transcribeAudio(
        apiKey _: String,
        model _: LLMModel,
        prompt _: String,
        wavData _: Data,
        mimeType _: String
    ) async throws -> PostProcessResult {
        PostProcessResult(text: audioTranscribeText, usage: nil)
    }
}

private final class FakeSTTService: STTService, @unchecked Sendable {
    let transcript: String?

    init(transcript: String?) {
        self.transcript = transcript
    }

    func startStreamingSessionIfNeeded(
        config _: Config,
        runID _: String,
        language _: String?,
        logger _: @escaping PipelineEventLogger
    ) -> (any STTStreamingSession)? {
        nil
    }

    func transcribe(
        config _: Config,
        recording _: RecordingResult,
        language _: String?,
        runID _: String,
        streamingSession _: (any STTStreamingSession)?,
        logger _: @escaping PipelineEventLogger
    ) async throws -> STTTranscriptionResult {
        guard let transcript else {
            throw AppError.invalidArgument("stt_error")
        }
        return STTTranscriptionResult(
            transcript: transcript,
            usage: nil,
            trace: STTTraceFactory.singleAttemptTrace(
                provider: "deepgram",
                route: .rest,
                kind: .rest,
                eventStartMs: 100,
                eventEndMs: 120,
                source: "rest",
                textChars: transcript.count,
                sampleRate: 16_000,
                audioBytes: 3200
            )
        )
    }
}

private struct FakeOutputService: OutputService {
    let sendTextResult: Bool

    func playStartSound() -> Bool { true }
    func playCompletionSound() -> Bool { true }
    func sendText(_: String) -> Bool { sendTextResult }
}

private struct FakeAccessibilityProvider: AccessibilityContextProvider {
    func capture(frontmostApp _: NSRunningApplication?) -> AccessibilityContextCapture {
        AccessibilityContextCapture(
            snapshot: AccessibilitySnapshot(capturedAt: "2026-01-01T00:00:00Z", trusted: true),
            context: nil
        )
    }
}

private struct FakeVisionProvider: VisionContextProvider {
    func collect(
        mode: VisionContextMode,
        runID _: String,
        preferredWindowOwnerPID _: Int32?,
        runDirectory _: String?,
        logger _: @escaping PipelineEventLogger
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
            mode: mode.rawValue,
            error: nil
        )
    }
}
