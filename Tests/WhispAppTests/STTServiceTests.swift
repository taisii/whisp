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
            config: config(sttPreset: .deepgramStream),
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

    func testDeepgramTranscribeThrowsWhenFinalizeFails() async throws {
        let rest = FakeDeepgramRESTTranscriber(
            transcript: "fallback-rest-text",
            usage: STTUsage(durationSeconds: 0.8, requestID: "rest-1", provider: STTProvider.deepgram.rawValue)
        )
        let service = DeepgramSTTService(restClient: rest)
        let session = FakeStreamingSession(error: AppError.io("finalize failed"))

        do {
            _ = try await service.transcribe(
                config: config(sttPreset: .deepgramStream),
                recording: recording,
                language: "en",
                runID: "run-2",
                streamingSession: session,
                logger: { _, _ in }
            )
            XCTFail("expected transcribe to throw")
        } catch let error as AppError {
            guard case .io(let message) = error else {
                return XCTFail("unexpected AppError: \(error)")
            }
            XCTAssertTrue(message.contains("finalize failed"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let restCalls = await rest.callCount()
        XCTAssertEqual(restCalls, 0)
    }

    func testDeepgramTranscribeUsesRESTWhenNoStreamingSession() async throws {
        let rest = FakeDeepgramRESTTranscriber(
            transcript: "rest-text",
            usage: STTUsage(durationSeconds: 0.5, requestID: "rest-2", provider: STTProvider.deepgram.rawValue)
        )
        let service = DeepgramSTTService(restClient: rest)

        let result = try await service.transcribe(
            config: config(sttPreset: .deepgramRest),
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
            streamingSessionBuilder: { apiKey, language, runID, sampleRate, logger in
                recorder.build(
                    apiKey: apiKey,
                    language: language,
                    runID: runID,
                    sampleRate: sampleRate,
                    logger: logger
                )
            }
        )

        _ = service.startStreamingSessionIfNeeded(
            config: config(sttPreset: .deepgramStream),
            runID: "run-builder",
            language: "ja",
            logger: { _, _ in },
            onSegmentCommitted: nil
        )

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(recorder.lastAPIKey, "dg")
        XCTAssertEqual(recorder.lastLanguage, "ja")
        XCTAssertEqual(recorder.lastRunID, "run-builder")
        XCTAssertEqual(recorder.lastSampleRate, 16_000)
    }

    func testDeepgramStartStreamingSessionReturnsNilForDirectAudioModel() {
        let recorder = StreamingBuilderRecorder(sessionToReturn: FakeStreamingSession(result: STTStreamingFinalizeResult(
            transcript: "stream",
            usage: nil,
            drainStats: STTStreamingDrainStats(submittedChunks: 0, submittedBytes: 0, droppedChunks: 0)
        )))
        var conf = config(sttPreset: .deepgramStream)
        conf.llmModel = .gemini25FlashLiteAudio

        let service = DeepgramSTTService(
            restClient: FakeDeepgramRESTTranscriber(transcript: "unused", usage: nil),
            streamingSessionBuilder: { apiKey, language, runID, sampleRate, logger in
                recorder.build(
                    apiKey: apiKey,
                    language: language,
                    runID: runID,
                    sampleRate: sampleRate,
                    logger: logger
                )
            }
        )

        let session = service.startStreamingSessionIfNeeded(
            config: conf,
            runID: "run-direct-audio",
            language: "ja",
            logger: { _, _ in },
            onSegmentCommitted: nil
        )

        XCTAssertNil(session)
        XCTAssertEqual(recorder.callCount, 0)
    }

    func testWhisperStartStreamingSessionUsesPresetSampleRatePolicy() {
        let recorder = StreamingBuilderRecorder(sessionToReturn: FakeStreamingSession(result: STTStreamingFinalizeResult(
            transcript: "stream",
            usage: nil,
            drainStats: STTStreamingDrainStats(submittedChunks: 0, submittedBytes: 0, droppedChunks: 0)
        )))
        let service = WhisperSTTService(
            client: FakeWhisperRESTTranscriber(transcript: "unused", usage: nil),
            streamingSessionBuilder: { apiKey, language, runID, sampleRate, logger in
                recorder.build(
                    apiKey: apiKey,
                    language: language,
                    runID: runID,
                    sampleRate: sampleRate,
                    logger: logger
                )
            }
        )

        _ = service.startStreamingSessionIfNeeded(
            config: config(sttPreset: .chatgptWhisperStream),
            runID: "run-whisper-builder",
            language: "ja",
            logger: { _, _ in },
            onSegmentCommitted: nil
        )

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(recorder.lastSampleRate, 24_000)
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
            config: config(sttPreset: .deepgramRest),
            recording: recording,
            language: nil,
            runID: "run-provider-deepgram",
            streamingSession: nil,
            logger: { _, _ in }
        )
        XCTAssertEqual(deepgramResult.transcript, "deepgram")

        let whisperSession = FakeStreamingSession(result: STTStreamingFinalizeResult(
            transcript: "whisper-stream",
            usage: nil,
            drainStats: STTStreamingDrainStats(submittedChunks: 1, submittedBytes: 32, droppedChunks: 0)
        ))
        let whisperResult = try await switching.transcribe(
            config: config(sttPreset: .chatgptWhisperStream),
            recording: recording,
            language: nil,
            runID: "run-provider-whisper",
            streamingSession: whisperSession,
            logger: { _, _ in }
        )
        XCTAssertEqual(whisperResult.transcript, "whisper-stream")

        let appleResult = try await switching.transcribe(
            config: config(sttPreset: .appleSpeechRecognizerRest),
            recording: recording,
            language: nil,
            runID: "run-provider-apple",
            streamingSession: nil,
            logger: { _, _ in }
        )
        XCTAssertEqual(appleResult.transcript, "apple")
    }

    func testProviderSwitchingRejectsMissingStreamingSessionForStreamPreset() async {
        let switching = ProviderSwitchingSTTService(
            deepgramService: DeepgramSTTService(restClient: FakeDeepgramRESTTranscriber(transcript: "unused", usage: nil)),
            whisperService: WhisperSTTService(client: FakeWhisperRESTTranscriber(transcript: "unused", usage: nil)),
            appleSpeechService: AppleSpeechSTTService(client: FakeAppleSpeechTranscriber(transcript: "unused", usage: nil))
        )

        do {
            _ = try await switching.transcribe(
                config: config(sttPreset: .chatgptWhisperStream),
                recording: recording,
                language: nil,
                runID: "run-provider-reject",
                streamingSession: nil,
                logger: { _, _ in }
            )
            XCTFail("expected transcribe to throw")
        } catch let error as AppError {
            guard case .io(let message) = error else {
                return XCTFail("unexpected AppError: \(error)")
            }
            XCTAssertTrue(message.contains("streaming session unavailable"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testWhisperServiceProducesWhisperRESTTrace() async throws {
        let whisper = FakeWhisperRESTTranscriber(
            transcript: "whisper-text",
            usage: STTUsage(durationSeconds: 1, requestID: "whisper-1", provider: STTProvider.whisper.rawValue)
        )
        let service = WhisperSTTService(client: whisper)

        let result = try await service.transcribe(
            config: config(sttPreset: .chatgptWhisperStream),
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

    func testWhisperServiceUsesStreamingFinalizeWhenSessionSucceeds() async throws {
        let whisper = FakeWhisperRESTTranscriber(transcript: "whisper-rest-unused", usage: nil)
        let service = WhisperSTTService(client: whisper)
        let session = FakeStreamingSession(result: STTStreamingFinalizeResult(
            transcript: "whisper-stream-text",
            usage: STTUsage(durationSeconds: 0.9, requestID: nil, provider: STTProvider.whisper.rawValue),
            drainStats: STTStreamingDrainStats(submittedChunks: 3, submittedBytes: 128, droppedChunks: 0)
        ))

        let result = try await service.transcribe(
            config: config(sttPreset: .chatgptWhisperStream),
            recording: recording,
            language: "ja",
            runID: "run-whisper-stream",
            streamingSession: session,
            logger: { _, _ in }
        )

        XCTAssertEqual(result.transcript, "whisper-stream-text")
        XCTAssertEqual(result.trace.route, .streaming)
        XCTAssertEqual(result.trace.attempts.count, 1)
        XCTAssertEqual(result.trace.attempts[0].kind, .streamFinalize)
        let whisperCalls = await whisper.callCount()
        XCTAssertEqual(whisperCalls, 0)
    }

    func testWhisperServiceThrowsWhenStreamingFails() async throws {
        let whisper = FakeWhisperRESTTranscriber(
            transcript: "whisper-rest-fallback",
            usage: STTUsage(durationSeconds: 1.1, requestID: nil, provider: STTProvider.whisper.rawValue)
        )
        let service = WhisperSTTService(client: whisper)
        let session = FakeStreamingSession(error: AppError.io("stream failed"))

        do {
            _ = try await service.transcribe(
                config: config(sttPreset: .chatgptWhisperStream),
                recording: recording,
                language: "en",
                runID: "run-whisper-fallback",
                streamingSession: session,
                logger: { _, _ in }
            )
            XCTFail("expected transcribe to throw")
        } catch let error as AppError {
            guard case .io(let message) = error else {
                return XCTFail("unexpected AppError: \(error)")
            }
            XCTAssertTrue(message.contains("stream failed"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let whisperCalls = await whisper.callCount()
        XCTAssertEqual(whisperCalls, 0)
    }

    func testAppleSpeechServiceProducesOnDeviceTrace() async throws {
        let apple = FakeAppleSpeechTranscriber(
            transcript: "apple-text",
            usage: STTUsage(durationSeconds: 1.5, requestID: nil, provider: STTProvider.appleSpeech.rawValue)
        )
        let service = AppleSpeechSTTService(client: apple)

        let result = try await service.transcribe(
            config: config(sttPreset: .appleSpeechRecognizerRest),
            recording: recording,
            language: "ja",
            runID: "run-apple",
            streamingSession: nil,
            logger: { _, _ in }
        )

        XCTAssertEqual(result.transcript, "apple-text")
        XCTAssertEqual(result.trace.route, .rest)
        XCTAssertEqual(result.trace.attempts.count, 1)
        XCTAssertEqual(result.trace.attempts[0].kind, .appleSpeech)
        XCTAssertEqual(result.trace.attempts[0].source, "apple_speech_recognizer_rest")
        let appleCalls = await apple.callCount()
        XCTAssertEqual(appleCalls, 1)
    }

    func testAppleSpeechServiceRoutesSpeechTranscriberRESTToDedicatedClient() async throws {
        let recognizer = FakeAppleSpeechTranscriber(transcript: "recognizer", usage: nil)
        let speech = FakeAppleSpeechTranscriber(transcript: "speech", usage: nil)
        let dictation = FakeAppleSpeechTranscriber(transcript: "dictation", usage: nil)
        let service = AppleSpeechSTTService(
            recognizerClient: recognizer,
            speechTranscriberClient: speech,
            dictationTranscriberClient: dictation
        )

        let result = try await service.transcribe(
            config: config(sttPreset: .appleSpeechTranscriberRest),
            recording: recording,
            language: "ja",
            runID: "run-apple-speech-transcriber-rest",
            streamingSession: nil,
            logger: { _, _ in }
        )

        XCTAssertEqual(result.transcript, "speech")
        XCTAssertEqual(result.trace.attempts[0].source, "apple_speech_transcriber_rest")
        let recognizerCalls = await recognizer.callCount()
        let speechCalls = await speech.callCount()
        let dictationCalls = await dictation.callCount()
        XCTAssertEqual(recognizerCalls, 0)
        XCTAssertEqual(speechCalls, 1)
        XCTAssertEqual(dictationCalls, 0)
    }

    func testAppleSpeechServiceRoutesDictationRESTToDedicatedClient() async throws {
        let recognizer = FakeAppleSpeechTranscriber(transcript: "recognizer", usage: nil)
        let speech = FakeAppleSpeechTranscriber(transcript: "speech", usage: nil)
        let dictation = FakeAppleSpeechTranscriber(transcript: "dictation", usage: nil)
        let service = AppleSpeechSTTService(
            recognizerClient: recognizer,
            speechTranscriberClient: speech,
            dictationTranscriberClient: dictation
        )

        let result = try await service.transcribe(
            config: config(sttPreset: .appleDictationTranscriberRest),
            recording: recording,
            language: "ja",
            runID: "run-apple-dictation-rest",
            streamingSession: nil,
            logger: { _, _ in }
        )

        XCTAssertEqual(result.transcript, "dictation")
        XCTAssertEqual(result.trace.attempts[0].source, "apple_dictation_transcriber_rest")
        let recognizerCalls = await recognizer.callCount()
        let speechCalls = await speech.callCount()
        let dictationCalls = await dictation.callCount()
        XCTAssertEqual(recognizerCalls, 0)
        XCTAssertEqual(speechCalls, 0)
        XCTAssertEqual(dictationCalls, 1)
    }

    func testAppleSpeechServiceUsesModelSpecificSourceForDictationStreaming() async throws {
        let service = AppleSpeechSTTService(
            recognizerClient: FakeAppleSpeechTranscriber(transcript: "recognizer", usage: nil),
            speechTranscriberClient: FakeAppleSpeechTranscriber(transcript: "speech", usage: nil),
            dictationTranscriberClient: FakeAppleSpeechTranscriber(transcript: "dictation", usage: nil)
        )
        let session = FakeStreamingSession(result: STTStreamingFinalizeResult(
            transcript: "streamed",
            usage: nil,
            drainStats: STTStreamingDrainStats(submittedChunks: 1, submittedBytes: 64, droppedChunks: 0)
        ))

        let result = try await service.transcribe(
            config: config(sttPreset: .appleDictationTranscriberStream),
            recording: recording,
            language: "ja",
            runID: "run-apple-dictation-stream",
            streamingSession: session,
            logger: { _, _ in }
        )

        XCTAssertEqual(result.transcript, "streamed")
        XCTAssertEqual(result.trace.attempts[0].source, "apple_dictation_transcriber_stream")
    }

    func testAppleSpeechServiceUsesStreamingFinalizeWhenSessionSucceeds() async throws {
        let apple = FakeAppleSpeechTranscriber(transcript: "apple-rest-unused", usage: nil)
        let service = AppleSpeechSTTService(client: apple)
        let session = FakeStreamingSession(result: STTStreamingFinalizeResult(
            transcript: "apple-stream-text",
            usage: STTUsage(durationSeconds: 0.7, requestID: nil, provider: STTProvider.appleSpeech.rawValue),
            drainStats: STTStreamingDrainStats(submittedChunks: 5, submittedBytes: 240, droppedChunks: 0)
        ))

        let result = try await service.transcribe(
            config: config(sttPreset: .appleSpeechRecognizerStream),
            recording: recording,
            language: "ja",
            runID: "run-apple-stream",
            streamingSession: session,
            logger: { _, _ in }
        )

        XCTAssertEqual(result.transcript, "apple-stream-text")
        XCTAssertEqual(result.trace.route, .streaming)
        XCTAssertEqual(result.trace.transport, .onDevice)
        XCTAssertEqual(result.trace.attempts.count, 1)
        XCTAssertEqual(result.trace.attempts[0].kind, .streamFinalize)
        XCTAssertEqual(result.trace.attempts[0].submittedChunks, 5)
        let appleCalls = await apple.callCount()
        XCTAssertEqual(appleCalls, 0)
    }

    func testAppleSpeechServiceStreamingReturnsCommittedSegments() async throws {
        let recognizer = FakeAppleSpeechTranscriber(transcript: "recognizer-rest", usage: nil)
        let service = AppleSpeechSTTService(
            recognizerClient: recognizer
        )

        let recognizerSession = FakeStreamingSession(result: STTStreamingFinalizeResult(
            transcript: "one\ntwo",
            usage: nil,
            drainStats: STTStreamingDrainStats(submittedChunks: 2, submittedBytes: 320, droppedChunks: 0),
            segments: [
                STTCommittedSegment(index: 0, startMs: 0, endMs: 500, text: "one", reason: "silence"),
                STTCommittedSegment(index: 1, startMs: 500, endMs: 900, text: "two", reason: "stop"),
            ],
            vadIntervals: [
                VADInterval(startMs: 0, endMs: 450, kind: "speech"),
                VADInterval(startMs: 450, endMs: 900, kind: "silence"),
            ]
        ))
        let recognizerResult = try await service.transcribe(
            config: config(sttPreset: .appleSpeechRecognizerStream),
            recording: recording,
            language: nil,
            runID: "run-apple-recognizer-stream-segments",
            streamingSession: recognizerSession,
            logger: { _, _ in }
        )
        XCTAssertEqual(recognizerResult.segments.count, 2)
        XCTAssertEqual(recognizerResult.vadIntervals.count, 2)
    }

    func testAppleSpeechSegmentingSessionSplitsOnSilence() async throws {
        let transcriber = ScriptedAppleSpeechTranscriber(segmentTranscripts: ["first", "second"])
        let session = AppleSpeechSegmentingSession(
            transcriber: transcriber,
            sampleRate: 16_000,
            language: nil,
            segmentation: STTSegmentationConfig(silenceMs: 100, maxSegmentMs: 10_000, preRollMs: 0, livePreviewEnabled: false),
            logger: { _, _ in },
            runID: "run-segment-silence",
            onSegmentCommitted: nil
        )
        session.submit(chunk: makePCMChunk(ms: 80, amplitude: 10_000))
        session.submit(chunk: makePCMChunk(ms: 120, amplitude: 0))
        session.submit(chunk: makePCMChunk(ms: 80, amplitude: 12_000))
        let result = try await session.finish()

        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments.first?.reason, "silence")
        XCTAssertEqual(result.segments.last?.reason, "stop")
    }

    func testAppleSpeechSegmentingSessionSplitsOnMaxSegment() async throws {
        let transcriber = ScriptedAppleSpeechTranscriber(segmentTranscripts: ["part1", "part2"])
        let session = AppleSpeechSegmentingSession(
            transcriber: transcriber,
            sampleRate: 16_000,
            language: nil,
            segmentation: STTSegmentationConfig(silenceMs: 1_000, maxSegmentMs: 100, preRollMs: 0, livePreviewEnabled: false),
            logger: { _, _ in },
            runID: "run-segment-max",
            onSegmentCommitted: nil
        )
        session.submit(chunk: makePCMChunk(ms: 60, amplitude: 9_000))
        session.submit(chunk: makePCMChunk(ms: 60, amplitude: 9_000))
        session.submit(chunk: makePCMChunk(ms: 40, amplitude: 9_000))
        let result = try await session.finish()

        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments.first?.reason, "max_segment")
        XCTAssertEqual(result.segments.last?.reason, "stop")
    }

    func testAppleSpeechServiceThrowsWhenStreamingFails() async throws {
        let apple = FakeAppleSpeechTranscriber(
            transcript: "apple-rest-fallback",
            usage: STTUsage(durationSeconds: 1.1, requestID: nil, provider: STTProvider.appleSpeech.rawValue)
        )
        let service = AppleSpeechSTTService(client: apple)
        let session = FakeStreamingSession(error: AppError.io("apple stream failed"))

        do {
            _ = try await service.transcribe(
                config: config(sttPreset: .appleSpeechRecognizerStream),
                recording: recording,
                language: "en",
                runID: "run-apple-fallback",
                streamingSession: session,
                logger: { _, _ in }
            )
            XCTFail("expected transcribe to throw")
        } catch let error as AppError {
            guard case .io(let message) = error else {
                return XCTFail("unexpected AppError: \(error)")
            }
            XCTAssertTrue(message.contains("apple stream failed"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let appleCalls = await apple.callCount()
        XCTAssertEqual(appleCalls, 0)
    }

    func testAppleSpeechStartStreamingSessionBuildsLiveSession() async throws {
        let apple = FakeAppleSpeechTranscriber(transcript: "unused", usage: nil)
        let service = AppleSpeechSTTService(client: apple)
        let logCollector = PipelineLogCollector()
        let session = service.startStreamingSessionIfNeeded(
            config: config(sttPreset: .appleSpeechRecognizerStream),
            runID: "run-apple-builder",
            language: "ja",
            logger: { event, attrs in
                logCollector.record(event: event, attrs: attrs)
            },
            onSegmentCommitted: nil
        )

        XCTAssertNotNil(session)
        XCTAssertEqual(logCollector.count(for: "stt_stream_connected"), 0)
        session?.submit(chunk: Data(repeating: 1, count: 320))
        _ = try await session?.finish()
        let startCalls = await apple.streamingStartCallCount()
        let finishCalls = await apple.streamingFinishCallCount()
        XCTAssertEqual(startCalls, 1)
        XCTAssertEqual(finishCalls, 1)
        XCTAssertEqual(logCollector.count(for: "stt_stream_connected"), 1)
    }

    func testAppleSpeechStartStreamingSessionReturnsNilForDirectAudioModel() {
        var conf = config(sttPreset: .appleSpeechRecognizerStream)
        conf.llmModel = .gemini25FlashLiteAudio
        let service = AppleSpeechSTTService(client: FakeAppleSpeechTranscriber(transcript: "unused", usage: nil))

        let session = service.startStreamingSessionIfNeeded(
            config: conf,
            runID: "run-apple-direct-audio",
            language: "ja",
            logger: { _, _ in },
            onSegmentCommitted: nil
        )

        XCTAssertNil(session)
    }

    private let recording = RecordingResult(sampleRate: 16_000, pcmData: Data(repeating: 1, count: 3_200))

    private func config(sttPreset: STTPresetID) -> Config {
        Config(
            apiKeys: APIKeys(deepgram: "dg", gemini: "gm", openai: "oa"),
            shortcut: "Cmd+J",
            inputLanguage: "ja",
            recordingMode: .toggle,
            sttPreset: sttPreset,
            appPromptRules: [],
            llmModel: .gemini25FlashLite,
            context: ContextConfig(visionEnabled: false, visionMode: .saveOnly)
        )
    }
}

private func makePCMChunk(ms: Int, amplitude: Int16) -> Data {
    let sampleRate = 16_000
    let sampleCount = max(1, sampleRate * ms / 1_000)
    let samples = [Int16](repeating: amplitude, count: sampleCount)
    return samples.withUnsafeBytes { rawBuffer in
        Data(rawBuffer)
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
    private let streamTranscript: String
    private let streamUsage: STTUsage?
    private let streamStartError: Error?
    private let streamFinishError: Error?
    private var calls: Int = 0
    private var streamStartCalls: Int = 0
    private var streamFinishCalls: Int = 0

    init(
        transcript: String,
        usage: STTUsage?,
        streamTranscript: String? = nil,
        streamUsage: STTUsage? = nil,
        streamStartError: Error? = nil,
        streamFinishError: Error? = nil
    ) {
        self.transcript = transcript
        self.usage = usage
        self.streamTranscript = streamTranscript ?? transcript
        self.streamUsage = streamUsage ?? usage
        self.streamStartError = streamStartError
        self.streamFinishError = streamFinishError
    }

    func transcribe(
        sampleRate _: Int,
        audio _: Data,
        language _: String?
    ) async throws -> (transcript: String, usage: STTUsage?) {
        calls += 1
        return (transcript, usage)
    }

    func startStreaming(
        sampleRate _: Int,
        language _: String?
    ) async throws {
        streamStartCalls += 1
        if let streamStartError {
            throw streamStartError
        }
    }

    func enqueueStreamingAudioChunk(_ chunk: Data) async {
        _ = chunk
    }

    func finishStreaming() async throws -> (transcript: String, usage: STTUsage?) {
        streamFinishCalls += 1
        if let streamFinishError {
            throw streamFinishError
        }
        return (streamTranscript, streamUsage)
    }

    func callCount() -> Int { calls }
    func streamingStartCallCount() -> Int { streamStartCalls }
    func streamingFinishCallCount() -> Int { streamFinishCalls }
}

private actor ScriptedAppleSpeechTranscriber: AppleSpeechTranscriber {
    private let segmentTranscripts: [String]
    private var segmentIndex = 0

    init(segmentTranscripts: [String]) {
        self.segmentTranscripts = segmentTranscripts
    }

    func transcribe(
        sampleRate _: Int,
        audio _: Data,
        language _: String?
    ) async throws -> (transcript: String, usage: STTUsage?) {
        ("", nil)
    }

    func startStreaming(
        sampleRate _: Int,
        language _: String?
    ) async throws {}

    func enqueueStreamingAudioChunk(_ chunk: Data) async {
        _ = chunk
    }

    func finishStreaming() async throws -> (transcript: String, usage: STTUsage?) {
        let currentIndex = segmentIndex
        segmentIndex += 1
        if currentIndex < segmentTranscripts.count {
            return (segmentTranscripts[currentIndex], nil)
        }
        return ("", nil)
    }
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
    private(set) var lastSampleRate: Int?
    private let sessionToReturn: (any STTStreamingSession)?

    init(sessionToReturn: (any STTStreamingSession)?) {
        self.sessionToReturn = sessionToReturn
    }

    func build(
        apiKey: String,
        language: String?,
        runID: String,
        sampleRate: Int,
        logger _: @escaping PipelineEventLogger
    ) -> (any STTStreamingSession)? {
        lock.lock()
        callCount += 1
        lastAPIKey = apiKey
        lastLanguage = language
        lastRunID = runID
        lastSampleRate = sampleRate
        lock.unlock()
        return sessionToReturn
    }
}

private final class PipelineLogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var attrsList: [[String: String]] = []

    func record(event: String, attrs: [String: String]) {
        lock.lock()
        events.append(event)
        attrsList.append(attrs)
        lock.unlock()
    }

    func count(for event: String) -> Int {
        lock.lock()
        let result = events.filter { $0 == event }.count
        lock.unlock()
        return result
    }
}
