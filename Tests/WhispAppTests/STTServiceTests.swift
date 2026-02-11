import Foundation
import XCTest
import WhispCore
@testable import WhispApp

final class STTServiceTests: XCTestCase {
    func testDeepgramTranscribeUsesStreamingFinalizeWhenSessionSucceeds() async throws {
        let rest = FakeDeepgramRESTTranscriber(transcript: "rest-unused", usage: nil)
        let service = DeepgramSTTService(restClient: rest)
        let session = FakeStreamingSession(result: STTStreamingFinalizeResult(
            transcript: "stream-text",
            usage: STTUsage(durationSeconds: 1.2, requestID: "stream-1", provider: STTProvider.deepgram.rawValue),
            drainStats: STTStreamingDrainStats(submittedChunks: 2, submittedBytes: 64, droppedChunks: 0)
        ))

        let result = try await service.transcribe(
            config: config(sttProvider: .deepgram),
            recording: recording,
            language: "ja",
            runID: "run-1",
            streamingSession: session,
            logger: { _, _ in }
        )

        XCTAssertEqual(result.transcript, "stream-text")
        XCTAssertEqual(result.trace.route, .streaming)
        XCTAssertEqual(result.trace.attempts.count, 1)
        XCTAssertEqual(result.trace.attempts.first?.kind, .streamFinalize)
        XCTAssertEqual(result.trace.attempts.first?.status, .ok)
        XCTAssertEqual(result.trace.attempts.first?.submittedChunks, 2)
        XCTAssertEqual(result.trace.attempts.first?.submittedBytes, 64)
        XCTAssertEqual(result.trace.attempts.first?.droppedChunks, 0)
        let restCalls = await rest.callCount()
        XCTAssertEqual(restCalls, 0)
    }

    func testDeepgramTranscribeFallsBackToRESTWhenFinalizeFails() async throws {
        let rest = FakeDeepgramRESTTranscriber(
            transcript: "fallback-rest-text",
            usage: STTUsage(durationSeconds: 0.8, requestID: "rest-1", provider: STTProvider.deepgram.rawValue)
        )
        let service = DeepgramSTTService(restClient: rest)
        let session = FakeStreamingSession(error: AppError.io("finalize failed"))

        let result = try await service.transcribe(
            config: config(sttProvider: .deepgram),
            recording: recording,
            language: "en",
            runID: "run-2",
            streamingSession: session,
            logger: { _, _ in }
        )

        XCTAssertEqual(result.transcript, "fallback-rest-text")
        XCTAssertEqual(result.trace.route, .streamingFallbackREST)
        XCTAssertEqual(result.trace.attempts.count, 2)
        XCTAssertEqual(result.trace.attempts[0].kind, .streamFinalize)
        XCTAssertEqual(result.trace.attempts[0].status, .error)
        XCTAssertEqual(result.trace.attempts[1].kind, .restFallback)
        XCTAssertEqual(result.trace.attempts[1].status, .ok)
        let restCalls = await rest.callCount()
        let lastLanguage = await rest.lastLanguage()
        XCTAssertEqual(restCalls, 1)
        XCTAssertEqual(lastLanguage, "en")
    }

    func testDeepgramTranscribeUsesRESTWhenNoStreamingSession() async throws {
        let rest = FakeDeepgramRESTTranscriber(
            transcript: "rest-text",
            usage: STTUsage(durationSeconds: 0.5, requestID: "rest-2", provider: STTProvider.deepgram.rawValue)
        )
        let service = DeepgramSTTService(restClient: rest)

        let result = try await service.transcribe(
            config: config(sttProvider: .deepgram),
            recording: recording,
            language: nil,
            runID: "run-3",
            streamingSession: nil,
            logger: { _, _ in }
        )

        XCTAssertEqual(result.transcript, "rest-text")
        XCTAssertEqual(result.trace.route, .rest)
        XCTAssertEqual(result.trace.attempts.count, 1)
        XCTAssertEqual(result.trace.attempts[0].kind, .rest)
        XCTAssertEqual(result.trace.attempts[0].status, .ok)
        let restCalls = await rest.callCount()
        let lastLanguage = await rest.lastLanguage()
        XCTAssertEqual(restCalls, 1)
        XCTAssertNil(lastLanguage)
    }

    func testDeepgramStartStreamingSessionUsesInjectedBuilder() {
        let recorder = StreamingBuilderRecorder(sessionToReturn: FakeStreamingSession(result: STTStreamingFinalizeResult(
            transcript: "stream",
            usage: nil,
            drainStats: STTStreamingDrainStats(submittedChunks: 0, submittedBytes: 0, droppedChunks: 0)
        )))
        let service = DeepgramSTTService(
            restClient: FakeDeepgramRESTTranscriber(transcript: "unused", usage: nil),
            streamingSessionBuilder: { apiKey, language, runID, logger in
                recorder.build(apiKey: apiKey, language: language, runID: runID, logger: logger)
            }
        )

        _ = service.startStreamingSessionIfNeeded(
            config: config(sttProvider: .deepgram),
            runID: "run-builder",
            language: "ja",
            logger: { _, _ in }
        )

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(recorder.lastAPIKey, "dg")
        XCTAssertEqual(recorder.lastLanguage, "ja")
        XCTAssertEqual(recorder.lastRunID, "run-builder")
    }

    func testDeepgramStartStreamingSessionReturnsNilForDirectAudioModel() {
        let recorder = StreamingBuilderRecorder(sessionToReturn: FakeStreamingSession(result: STTStreamingFinalizeResult(
            transcript: "stream",
            usage: nil,
            drainStats: STTStreamingDrainStats(submittedChunks: 0, submittedBytes: 0, droppedChunks: 0)
        )))
        var conf = config(sttProvider: .deepgram)
        conf.llmModel = .gemini25FlashLiteAudio

        let service = DeepgramSTTService(
            restClient: FakeDeepgramRESTTranscriber(transcript: "unused", usage: nil),
            streamingSessionBuilder: { apiKey, language, runID, logger in
                recorder.build(apiKey: apiKey, language: language, runID: runID, logger: logger)
            }
        )

        let session = service.startStreamingSessionIfNeeded(
            config: conf,
            runID: "run-direct-audio",
            language: "ja",
            logger: { _, _ in }
        )

        XCTAssertNil(session)
        XCTAssertEqual(recorder.callCount, 0)
    }

    func testProviderSwitchingUsesConfiguredProvider() async throws {
        let deepgramRest = FakeDeepgramRESTTranscriber(transcript: "deepgram", usage: nil)
        let whisperRest = FakeWhisperRESTTranscriber(transcript: "whisper", usage: nil)
        let appleSpeech = FakeAppleSpeechTranscriber(transcript: "apple", usage: nil)

        let switching = ProviderSwitchingSTTService(
            deepgramService: DeepgramSTTService(restClient: deepgramRest),
            whisperService: WhisperSTTService(client: whisperRest),
            appleSpeechService: AppleSpeechSTTService(client: appleSpeech)
        )

        let deepgramResult = try await switching.transcribe(
            config: config(sttProvider: .deepgram),
            recording: recording,
            language: nil,
            runID: "run-provider-deepgram",
            streamingSession: nil,
            logger: { _, _ in }
        )
        XCTAssertEqual(deepgramResult.transcript, "deepgram")

        let whisperResult = try await switching.transcribe(
            config: config(sttProvider: .whisper),
            recording: recording,
            language: nil,
            runID: "run-provider-whisper",
            streamingSession: nil,
            logger: { _, _ in }
        )
        XCTAssertEqual(whisperResult.transcript, "whisper")

        let appleResult = try await switching.transcribe(
            config: config(sttProvider: .appleSpeech),
            recording: recording,
            language: nil,
            runID: "run-provider-apple",
            streamingSession: nil,
            logger: { _, _ in }
        )
        XCTAssertEqual(appleResult.transcript, "apple")
    }

    func testWhisperServiceProducesWhisperRESTTrace() async throws {
        let whisper = FakeWhisperRESTTranscriber(
            transcript: "whisper-text",
            usage: STTUsage(durationSeconds: 1, requestID: "whisper-1", provider: STTProvider.whisper.rawValue)
        )
        let service = WhisperSTTService(client: whisper)

        let result = try await service.transcribe(
            config: config(sttProvider: .whisper),
            recording: recording,
            language: "en",
            runID: "run-whisper",
            streamingSession: nil,
            logger: { _, _ in }
        )

        XCTAssertEqual(result.transcript, "whisper-text")
        XCTAssertEqual(result.trace.route, .rest)
        XCTAssertEqual(result.trace.attempts.count, 1)
        XCTAssertEqual(result.trace.attempts[0].kind, .whisperREST)
        XCTAssertEqual(result.trace.attempts[0].source, "whisper_rest")
        let whisperCalls = await whisper.callCount()
        XCTAssertEqual(whisperCalls, 1)
    }

    func testAppleSpeechServiceProducesOnDeviceTrace() async throws {
        let apple = FakeAppleSpeechTranscriber(
            transcript: "apple-text",
            usage: STTUsage(durationSeconds: 1.5, requestID: nil, provider: STTProvider.appleSpeech.rawValue)
        )
        let service = AppleSpeechSTTService(client: apple)

        let result = try await service.transcribe(
            config: config(sttProvider: .appleSpeech),
            recording: recording,
            language: "ja",
            runID: "run-apple",
            streamingSession: nil,
            logger: { _, _ in }
        )

        XCTAssertEqual(result.transcript, "apple-text")
        XCTAssertEqual(result.trace.route, .onDevice)
        XCTAssertEqual(result.trace.attempts.count, 1)
        XCTAssertEqual(result.trace.attempts[0].kind, .appleSpeech)
        XCTAssertEqual(result.trace.attempts[0].source, "apple_speech")
        let appleCalls = await apple.callCount()
        XCTAssertEqual(appleCalls, 1)
    }

    private let recording = RecordingResult(sampleRate: 16_000, pcmData: Data(repeating: 1, count: 3_200))

    private func config(sttProvider: STTProvider) -> Config {
        Config(
            apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa"),
            shortcut: "Cmd+J",
            inputLanguage: "ja",
            recordingMode: .toggle,
            sttProvider: sttProvider,
            appPromptRules: [],
            llmModel: .gemini25FlashLite,
            context: ContextConfig(visionEnabled: false, visionMode: .saveOnly)
        )
    }
}

private actor FakeDeepgramRESTTranscriber: DeepgramRESTTranscriber {
    private let transcript: String
    private let usage: STTUsage?
    private var calls: Int = 0
    private var languageValue: String?

    init(transcript: String, usage: STTUsage?) {
        self.transcript = transcript
        self.usage = usage
    }

    func transcribe(
        apiKey _: String,
        sampleRate _: Int,
        audio _: Data,
        language: String?
    ) async throws -> (transcript: String, usage: STTUsage?) {
        calls += 1
        languageValue = language
        return (transcript, usage)
    }

    func callCount() -> Int { calls }
    func lastLanguage() -> String? { languageValue }
}

private actor FakeWhisperRESTTranscriber: WhisperRESTTranscriber {
    private let transcript: String
    private let usage: STTUsage?
    private var calls: Int = 0

    init(transcript: String, usage: STTUsage?) {
        self.transcript = transcript
        self.usage = usage
    }

    func transcribe(
        apiKey _: String,
        sampleRate _: Int,
        audio _: Data,
        language _: String?
    ) async throws -> (transcript: String, usage: STTUsage?) {
        calls += 1
        return (transcript, usage)
    }

    func callCount() -> Int { calls }
}

private actor FakeAppleSpeechTranscriber: AppleSpeechTranscriber {
    private let transcript: String
    private let usage: STTUsage?
    private var calls: Int = 0

    init(transcript: String, usage: STTUsage?) {
        self.transcript = transcript
        self.usage = usage
    }

    func transcribe(
        sampleRate _: Int,
        audio _: Data,
        language _: String?
    ) async throws -> (transcript: String, usage: STTUsage?) {
        calls += 1
        return (transcript, usage)
    }

    func callCount() -> Int { calls }
}

private final class FakeStreamingSession: STTStreamingSession, @unchecked Sendable {
    private let result: STTStreamingFinalizeResult?
    private let error: Error?

    init(result: STTStreamingFinalizeResult) {
        self.result = result
        error = nil
    }

    init(error: Error) {
        result = nil
        self.error = error
    }

    func submit(chunk _: Data) {}

    func finish() async throws -> STTStreamingFinalizeResult {
        if let error {
            throw error
        }
        guard let result else {
            throw AppError.io("missing streaming result")
        }
        return result
    }
}

private final class StreamingBuilderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var callCount = 0
    private(set) var lastAPIKey: String?
    private(set) var lastLanguage: String?
    private(set) var lastRunID: String?
    private let sessionToReturn: (any STTStreamingSession)?

    init(sessionToReturn: (any STTStreamingSession)?) {
        self.sessionToReturn = sessionToReturn
    }

    func build(
        apiKey: String,
        language: String?,
        runID: String,
        logger _: @escaping PipelineEventLogger
    ) -> (any STTStreamingSession)? {
        lock.lock()
        callCount += 1
        lastAPIKey = apiKey
        lastLanguage = language
        lastRunID = runID
        lock.unlock()
        return sessionToReturn
    }
}
