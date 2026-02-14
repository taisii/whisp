import Foundation
import WhispCore

private func epochMsString(_ date: Date = Date()) -> String {
    WhispTime.epochMsString(date)
}

private func epochMs(_ date: Date = Date()) -> Int64 {
    WhispTime.epochMs(date)
}

struct STTStreamingDrainStats {
    let submittedChunks: Int
    let submittedBytes: Int
    let droppedChunks: Int
}

struct STTStreamingFinalizeResult {
    let transcript: String
    let usage: STTUsage?
    let drainStats: STTStreamingDrainStats
    let segments: [STTCommittedSegment]
    let vadIntervals: [VADInterval]

    init(
        transcript: String,
        usage: STTUsage?,
        drainStats: STTStreamingDrainStats,
        segments: [STTCommittedSegment] = [],
        vadIntervals: [VADInterval] = []
    ) {
        self.transcript = transcript
        self.usage = usage
        self.drainStats = drainStats
        self.segments = segments
        self.vadIntervals = vadIntervals
    }
}

protocol STTStreamingSession: AnyObject, Sendable {
    func submit(chunk: Data)
    func finish() async throws -> STTStreamingFinalizeResult
}

protocol STTService: Sendable {
    func startStreamingSessionIfNeeded(
        config: Config,
        runID: String,
        language: String?,
        logger: @escaping PipelineEventLogger,
        onSegmentCommitted: STTSegmentCommitHandler?
    ) -> (any STTStreamingSession)?

    func transcribe(
        config: Config,
        recording: RecordingResult,
        language: String?,
        runID: String,
        streamingSession: (any STTStreamingSession)?,
        logger: @escaping PipelineEventLogger
    ) async throws -> STTTranscriptionResult
}

typealias STTSegmentCommitHandler = @Sendable (STTCommittedSegment) -> Void

protocol DeepgramRESTTranscriber: Sendable {
    func transcribe(
        apiKey: String,
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> (transcript: String, usage: STTUsage?)
}

extension DeepgramClient: DeepgramRESTTranscriber {}

protocol WhisperRESTTranscriber: Sendable {
    func transcribe(
        apiKey: String,
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> (transcript: String, usage: STTUsage?)
}

extension WhisperClient: WhisperRESTTranscriber {}

protocol OpenAIRealtimeStreamingTranscriber: Sendable {
    func start(
        apiKey: String,
        sampleRate: Int,
        language: String?,
        model: String
    ) async throws
    func enqueueAudioChunk(_ chunk: Data) async
    func finish() async throws -> (transcript: String, usage: STTUsage?)
}

extension OpenAIRealtimeStreamingClient: OpenAIRealtimeStreamingTranscriber {}

protocol AppleSpeechTranscriber: Sendable {
    func transcribe(
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> (transcript: String, usage: STTUsage?)
    func startStreaming(
        sampleRate: Int,
        language: String?
    ) async throws
    func enqueueStreamingAudioChunk(_ chunk: Data) async
    func finishStreaming() async throws -> (transcript: String, usage: STTUsage?)
}

typealias DeepgramStreamingSessionBuilder = @Sendable (
    _ apiKey: String,
    _ language: String?,
    _ runID: String,
    _ sampleRate: Int,
    _ logger: @escaping PipelineEventLogger
) -> (any STTStreamingSession)?

typealias OpenAIStreamingSessionBuilder = @Sendable (
    _ apiKey: String,
    _ language: String?,
    _ runID: String,
    _ sampleRate: Int,
    _ logger: @escaping PipelineEventLogger
) -> (any STTStreamingSession)?

final class ProviderSwitchingSTTService: STTService, @unchecked Sendable {
    private let deepgramService: DeepgramSTTService
    private let whisperService: WhisperSTTService
    private let appleSpeechService: AppleSpeechSTTService

    init(
        deepgramService: DeepgramSTTService = DeepgramSTTService(),
        whisperService: WhisperSTTService = WhisperSTTService(),
        appleSpeechService: AppleSpeechSTTService = AppleSpeechSTTService()
    ) {
        self.deepgramService = deepgramService
        self.whisperService = whisperService
        self.appleSpeechService = appleSpeechService
    }

    func startStreamingSessionIfNeeded(
        config: Config,
        runID: String,
        language: String?,
        logger: @escaping PipelineEventLogger,
        onSegmentCommitted: STTSegmentCommitHandler?
    ) -> (any STTStreamingSession)? {
        let preset = STTPresetCatalog.spec(for: config.sttPreset)
        guard preset.mode == .stream else {
            return nil
        }
        return service(for: preset.engine).startStreamingSessionIfNeeded(
            config: config,
            runID: runID,
            language: language,
            logger: logger,
            onSegmentCommitted: onSegmentCommitted
        )
    }

    func transcribe(
        config: Config,
        recording: RecordingResult,
        language: String?,
        runID: String,
        streamingSession: (any STTStreamingSession)?,
        logger: @escaping PipelineEventLogger
    ) async throws -> STTTranscriptionResult {
        let preset = STTPresetCatalog.spec(for: config.sttPreset)
        if preset.mode == .stream, streamingSession == nil {
            throw AppError.io("STT streaming session unavailable: \(config.sttPreset.rawValue)")
        }
        return try await service(for: preset.engine).transcribe(
            config: config,
            recording: recording,
            language: language,
            runID: runID,
            streamingSession: preset.mode == .stream ? streamingSession : nil,
            logger: logger
        )
    }

    private func service(for engine: STTEngine) -> any STTService {
        switch engine {
        case .deepgram:
            return deepgramService
        case .openAIWhisper:
            return whisperService
        case .appleSpeech:
            return appleSpeechService
        }
    }
}

final class DeepgramSTTService: STTService, @unchecked Sendable {
    private let restClient: any DeepgramRESTTranscriber
    private let streamingSessionBuilder: DeepgramStreamingSessionBuilder

    init(
        restClient: any DeepgramRESTTranscriber = DeepgramClient(),
        streamingSessionBuilder: DeepgramStreamingSessionBuilder? = nil
    ) {
        self.restClient = restClient
        self.streamingSessionBuilder = streamingSessionBuilder ?? Self.defaultStreamingSessionBuilder
    }

    func startStreamingSessionIfNeeded(
        config: Config,
        runID: String,
        language: String?,
        logger: @escaping PipelineEventLogger,
        onSegmentCommitted _: STTSegmentCommitHandler?
    ) -> (any STTStreamingSession)? {
        guard !config.llmModel.usesDirectAudio else {
            return nil
        }
        guard case let .apiKey(deepgramKey) = (try? APIKeyResolver.sttCredential(config: config, preset: config.sttPreset)) else {
            return nil
        }
        let targetSampleRate = STTPresetCatalog.targetInputSampleRate(for: config.sttPreset)

        return streamingSessionBuilder(deepgramKey, language, runID, targetSampleRate, logger)
    }

    private static func defaultStreamingSessionBuilder(
        apiKey: String,
        language: String?,
        runID: String,
        sampleRate: Int,
        logger: @escaping PipelineEventLogger
    ) -> (any STTStreamingSession)? {
        let stream = DeepgramStreamingClient()
        let session = DeepgramLiveSession(stream: stream, logger: logger, runID: runID)
        Task {
            do {
                try await stream.start(
                    apiKey: apiKey,
                    sampleRate: sampleRate,
                    language: language
                )
                logger("stt_stream_connected", [
                    "sample_rate": String(sampleRate),
                    "language": language ?? "auto",
                ])
            } catch {
                logger("stt_stream_connect_failed", [
                    "error": error.localizedDescription,
                ])
            }
        }
        return session
    }

    func transcribe(
        config: Config,
        recording: RecordingResult,
        language: String?,
        runID _: String,
        streamingSession: (any STTStreamingSession)?,
        logger: @escaping PipelineEventLogger
    ) async throws -> STTTranscriptionResult {
        let credential = try APIKeyResolver.sttCredential(config: config, preset: config.sttPreset)
        guard case let .apiKey(deepgramKey) = credential else {
            throw AppError.invalidArgument("Deepgram APIキーが未設定です")
        }

        if let streamingSession {
            let finalizeRequestedAt = Date()
            let finalizeRequestedAtMs = epochMs(finalizeRequestedAt)
            logger("stt_stream_finalize_start", [
                "request_sent_at_ms": epochMsString(finalizeRequestedAt),
            ])
            let result = try await streamingSession.finish()
            let finalizeResponseAt = Date()
            let finalizeResponseAtMs = epochMs(finalizeResponseAt)
            logger("stt_stream_finalize_done", [
                "request_sent_at_ms": epochMsString(finalizeRequestedAt),
                "response_received_at_ms": epochMsString(finalizeResponseAt),
                "text_chars": String(result.transcript.count),
            ])

            let attempt = STTTraceFactory.attempt(
                kind: .streamFinalize,
                status: .ok,
                eventStartMs: finalizeRequestedAtMs,
                eventEndMs: finalizeResponseAtMs,
                source: "stream_finalize",
                textChars: result.transcript.count,
                sampleRate: recording.sampleRate,
                audioBytes: recording.pcmData.count,
                submittedChunks: result.drainStats.submittedChunks,
                submittedBytes: result.drainStats.submittedBytes,
                droppedChunks: result.drainStats.droppedChunks
            )

            let trace = STTTraceFactory.trace(
                provider: config.sttPreset.rawValue,
                transport: .websocket,
                route: .streaming,
                eventStartMs: finalizeRequestedAtMs,
                eventEndMs: finalizeResponseAtMs,
                status: .ok,
                source: "stream_finalize",
                textChars: result.transcript.count,
                sampleRate: recording.sampleRate,
                audioBytes: recording.pcmData.count,
                attempts: [attempt]
            )
            return STTTranscriptionResult(transcript: result.transcript, usage: result.usage, trace: trace)
        }

        let restRequestedAt = Date()
        let restRequestedAtMs = epochMs(restRequestedAt)
        logger("stt_start", [
            "source": "rest",
            "sample_rate": String(recording.sampleRate),
            "audio_bytes": String(recording.pcmData.count),
            "request_sent_at_ms": epochMsString(restRequestedAt),
        ])
        let stt = try await restClient.transcribe(
            apiKey: deepgramKey,
            sampleRate: recording.sampleRate,
            audio: recording.pcmData,
            language: language
        )
        let restResponseAt = Date()
        let restResponseAtMs = epochMs(restResponseAt)
        logger("stt_done", [
            "source": "rest",
            "request_sent_at_ms": epochMsString(restRequestedAt),
            "response_received_at_ms": epochMsString(restResponseAt),
            "text_chars": String(stt.transcript.count),
        ])

        let trace = STTTraceFactory.singleAttemptTrace(
            provider: config.sttPreset.rawValue,
            transport: .rest,
            route: .rest,
            kind: .rest,
            eventStartMs: restRequestedAtMs,
            eventEndMs: restResponseAtMs,
            source: "rest",
            textChars: stt.transcript.count,
            sampleRate: recording.sampleRate,
            audioBytes: recording.pcmData.count
        )
        return STTTranscriptionResult(transcript: stt.transcript, usage: stt.usage, trace: trace)
    }
}

final class WhisperSTTService: STTService, @unchecked Sendable {
    private let client: any WhisperRESTTranscriber
    private let streamingSessionBuilder: OpenAIStreamingSessionBuilder

    init(
        client: any WhisperRESTTranscriber = WhisperClient(),
        streamingSessionBuilder: OpenAIStreamingSessionBuilder? = nil
    ) {
        self.client = client
        self.streamingSessionBuilder = streamingSessionBuilder ?? Self.defaultStreamingSessionBuilder
    }

    func startStreamingSessionIfNeeded(
        config: Config,
        runID: String,
        language: String?,
        logger: @escaping PipelineEventLogger,
        onSegmentCommitted _: STTSegmentCommitHandler?
    ) -> (any STTStreamingSession)? {
        guard !config.llmModel.usesDirectAudio else {
            return nil
        }
        guard case let .apiKey(openAIKey) = (try? APIKeyResolver.sttCredential(config: config, preset: config.sttPreset)) else {
            return nil
        }
        let targetSampleRate = STTPresetCatalog.targetInputSampleRate(for: config.sttPreset)
        return streamingSessionBuilder(openAIKey, language, runID, targetSampleRate, logger)
    }

    private static func defaultStreamingSessionBuilder(
        apiKey: String,
        language: String?,
        runID: String,
        sampleRate: Int,
        logger: @escaping PipelineEventLogger
    ) -> (any STTStreamingSession)? {
        let stream = OpenAIRealtimeStreamingClient()
        let session = OpenAIRealtimeSession(stream: stream, logger: logger, runID: runID)
        Task {
            do {
                try await stream.start(
                    apiKey: apiKey,
                    sampleRate: sampleRate,
                    language: language
                )
                logger("stt_stream_connected", [
                    "sample_rate": String(sampleRate),
                    "language": language ?? "auto",
                    "provider": STTProvider.whisper.rawValue,
                ])
            } catch {
                logger("stt_stream_connect_failed", [
                    "error": error.localizedDescription,
                    "provider": STTProvider.whisper.rawValue,
                ])
            }
        }
        return session
    }

    func transcribe(
        config: Config,
        recording: RecordingResult,
        language: String?,
        runID _: String,
        streamingSession: (any STTStreamingSession)?,
        logger: @escaping PipelineEventLogger
    ) async throws -> STTTranscriptionResult {
        let credential = try APIKeyResolver.sttCredential(config: config, preset: config.sttPreset)
        guard case let .apiKey(openAIKey) = credential else {
            throw AppError.invalidArgument("OpenAI APIキーが未設定です（Whisper STT）")
        }

        if let streamingSession {
            let finalizeRequestedAt = Date()
            let finalizeRequestedAtMs = epochMs(finalizeRequestedAt)
            logger("stt_stream_finalize_start", [
                "request_sent_at_ms": epochMsString(finalizeRequestedAt),
                "provider": config.sttPreset.rawValue,
            ])
            let result = try await streamingSession.finish()
            let finalizeResponseAt = Date()
            let finalizeResponseAtMs = epochMs(finalizeResponseAt)
            logger("stt_stream_finalize_done", [
                "request_sent_at_ms": epochMsString(finalizeRequestedAt),
                "response_received_at_ms": epochMsString(finalizeResponseAt),
                "text_chars": String(result.transcript.count),
                "provider": config.sttPreset.rawValue,
            ])

            let attempt = STTTraceFactory.attempt(
                kind: .streamFinalize,
                status: .ok,
                eventStartMs: finalizeRequestedAtMs,
                eventEndMs: finalizeResponseAtMs,
                source: "openai_realtime_stream",
                textChars: result.transcript.count,
                sampleRate: recording.sampleRate,
                audioBytes: recording.pcmData.count,
                submittedChunks: result.drainStats.submittedChunks,
                submittedBytes: result.drainStats.submittedBytes,
                droppedChunks: result.drainStats.droppedChunks
            )

            let trace = STTTraceFactory.trace(
                provider: config.sttPreset.rawValue,
                transport: .websocket,
                route: .streaming,
                eventStartMs: finalizeRequestedAtMs,
                eventEndMs: finalizeResponseAtMs,
                status: .ok,
                source: "openai_realtime_stream",
                textChars: result.transcript.count,
                sampleRate: recording.sampleRate,
                audioBytes: recording.pcmData.count,
                attempts: [attempt]
            )
            return STTTranscriptionResult(transcript: result.transcript, usage: result.usage, trace: trace)
        }

        let requestSentAt = Date()
        let requestSentAtMs = epochMs(requestSentAt)
        logger("stt_start", [
            "source": "whisper_rest",
            "sample_rate": String(recording.sampleRate),
            "audio_bytes": String(recording.pcmData.count),
            "request_sent_at_ms": epochMsString(requestSentAt),
        ])
        let stt = try await client.transcribe(
            apiKey: openAIKey,
            sampleRate: recording.sampleRate,
            audio: recording.pcmData,
            language: language
        )
        let responseReceivedAt = Date()
        let responseReceivedAtMs = epochMs(responseReceivedAt)
        logger("stt_done", [
            "source": "whisper_rest",
            "request_sent_at_ms": epochMsString(requestSentAt),
            "response_received_at_ms": epochMsString(responseReceivedAt),
            "text_chars": String(stt.transcript.count),
        ])

        let trace = STTTraceFactory.singleAttemptTrace(
            provider: config.sttPreset.rawValue,
            transport: .rest,
            route: .rest,
            kind: .whisperREST,
            eventStartMs: requestSentAtMs,
            eventEndMs: responseReceivedAtMs,
            source: "whisper_rest",
            textChars: stt.transcript.count,
            sampleRate: recording.sampleRate,
            audioBytes: recording.pcmData.count
        )
        return STTTranscriptionResult(transcript: stt.transcript, usage: stt.usage, trace: trace)
    }
}

final class AppleSpeechSTTService: STTService, @unchecked Sendable {
    private let recognizerClient: any AppleSpeechTranscriber
    private let speechTranscriberClient: any AppleSpeechTranscriber
    private let dictationTranscriberClient: any AppleSpeechTranscriber

    init(
        client: (any AppleSpeechTranscriber)? = nil,
        recognizerClient: (any AppleSpeechTranscriber)? = nil,
        speechTranscriberClient: (any AppleSpeechTranscriber)? = nil,
        dictationTranscriberClient: (any AppleSpeechTranscriber)? = nil
    ) {
        if let client {
            self.recognizerClient = client
            self.speechTranscriberClient = client
            self.dictationTranscriberClient = client
            return
        }
        self.recognizerClient = recognizerClient ?? AppleSpeechRecognizerClient()
        self.speechTranscriberClient = speechTranscriberClient ?? AppleSpeechTranscriberClient()
        self.dictationTranscriberClient = dictationTranscriberClient ?? AppleDictationTranscriberClient()
    }

    func startStreamingSessionIfNeeded(
        config: Config,
        runID: String,
        language: String?,
        logger: @escaping PipelineEventLogger,
        onSegmentCommitted: STTSegmentCommitHandler?
    ) -> (any STTStreamingSession)? {
        guard !config.llmModel.usesDirectAudio else {
            return nil
        }
        let targetSampleRate = STTPresetCatalog.targetInputSampleRate(for: config.sttPreset)
        let client = transcriber(for: config.sttPreset)
        return AppleSpeechSegmentingSession(
            transcriber: client,
            sampleRate: targetSampleRate,
            language: language,
            segmentation: config.sttSegmentation,
            logger: logger,
            runID: runID,
            onSegmentCommitted: onSegmentCommitted
        )
    }

    func transcribe(
        config: Config,
        recording: RecordingResult,
        language: String?,
        runID _: String,
        streamingSession: (any STTStreamingSession)?,
        logger: @escaping PipelineEventLogger
    ) async throws -> STTTranscriptionResult {
        let sourcePrefix = sourcePrefix(for: config.sttPreset)

        if let streamingSession {
            let finalizeRequestedAt = Date()
            let finalizeRequestedAtMs = epochMs(finalizeRequestedAt)
            logger("stt_stream_finalize_start", [
                "request_sent_at_ms": epochMsString(finalizeRequestedAt),
                "provider": config.sttPreset.rawValue,
            ])
            let result = try await streamingSession.finish()
            let finalizeResponseAt = Date()
            let finalizeResponseAtMs = epochMs(finalizeResponseAt)
            logger("stt_stream_finalize_done", [
                "request_sent_at_ms": epochMsString(finalizeRequestedAt),
                "response_received_at_ms": epochMsString(finalizeResponseAt),
                "text_chars": String(result.transcript.count),
                "provider": config.sttPreset.rawValue,
            ])

            let attempt = STTTraceFactory.attempt(
                kind: .streamFinalize,
                status: .ok,
                eventStartMs: finalizeRequestedAtMs,
                eventEndMs: finalizeResponseAtMs,
                source: "\(sourcePrefix)_stream",
                textChars: result.transcript.count,
                sampleRate: recording.sampleRate,
                audioBytes: recording.pcmData.count,
                submittedChunks: result.drainStats.submittedChunks,
                submittedBytes: result.drainStats.submittedBytes,
                droppedChunks: result.drainStats.droppedChunks
            )

            let trace = STTTraceFactory.trace(
                provider: config.sttPreset.rawValue,
                transport: .onDevice,
                route: .streaming,
                eventStartMs: finalizeRequestedAtMs,
                eventEndMs: finalizeResponseAtMs,
                status: .ok,
                source: "\(sourcePrefix)_stream",
                textChars: result.transcript.count,
                sampleRate: recording.sampleRate,
                audioBytes: recording.pcmData.count,
                attempts: [attempt]
            )
            return STTTranscriptionResult(
                transcript: result.transcript,
                usage: result.usage,
                trace: trace,
                segments: result.segments,
                vadIntervals: result.vadIntervals
            )
        }

        let requestSentAt = Date()
        let requestSentAtMs = epochMs(requestSentAt)
        logger("stt_start", [
            "source": "\(sourcePrefix)_rest",
            "sample_rate": String(recording.sampleRate),
            "audio_bytes": String(recording.pcmData.count),
            "request_sent_at_ms": epochMsString(requestSentAt),
        ])
        let client = transcriber(for: config.sttPreset)
        let stt = try await client.transcribe(
            sampleRate: recording.sampleRate,
            audio: recording.pcmData,
            language: language
        )
        let responseReceivedAt = Date()
        let responseReceivedAtMs = epochMs(responseReceivedAt)
        logger("stt_done", [
            "source": "\(sourcePrefix)_rest",
            "request_sent_at_ms": epochMsString(requestSentAt),
            "response_received_at_ms": epochMsString(responseReceivedAt),
            "text_chars": String(stt.transcript.count),
        ])

        let trace = STTTraceFactory.singleAttemptTrace(
            provider: config.sttPreset.rawValue,
            transport: .onDevice,
            route: .rest,
            kind: .appleSpeech,
            eventStartMs: requestSentAtMs,
            eventEndMs: responseReceivedAtMs,
            source: "\(sourcePrefix)_rest",
            textChars: stt.transcript.count,
            sampleRate: recording.sampleRate,
            audioBytes: recording.pcmData.count
        )
        return STTTranscriptionResult(transcript: stt.transcript, usage: stt.usage, trace: trace)
    }

    private func transcriber(for preset: STTPresetID) -> any AppleSpeechTranscriber {
        let spec = STTPresetCatalog.spec(for: preset)
        switch spec.appleModel {
        case .speechTranscriber:
            return speechTranscriberClient
        case .dictationTranscriber:
            return dictationTranscriberClient
        case .recognizer, .none:
            return recognizerClient
        }
    }

    private func sourcePrefix(for preset: STTPresetID) -> String {
        let spec = STTPresetCatalog.spec(for: preset)
        switch spec.appleModel {
        case .speechTranscriber:
            return "apple_speech_transcriber"
        case .dictationTranscriber:
            return "apple_dictation_transcriber"
        case .recognizer, .none:
            return "apple_speech_recognizer"
        }
    }
}

private final class AppleSpeechLiveSession: STTStreamingSession, @unchecked Sendable {
    private final class ChunkTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var pendingTasks: [Task<Void, Never>] = []
        private var closed = false
        private var submittedChunks = 0
        private var submittedBytes = 0
        private var droppedChunks = 0

        func submit(_ task: Task<Void, Never>, chunkSize: Int) {
            guard chunkSize > 0 else {
                return
            }
            lock.lock()
            if closed {
                droppedChunks += 1
                lock.unlock()
                return
            }
            submittedChunks += 1
            submittedBytes += chunkSize
            pendingTasks.append(task)
            lock.unlock()
        }

        func close() -> [Task<Void, Never>] {
            lock.lock()
            closed = true
            let tasks = pendingTasks
            pendingTasks.removeAll(keepingCapacity: false)
            lock.unlock()
            return tasks
        }

        func stats() -> STTStreamingDrainStats {
            lock.lock()
            let stats = STTStreamingDrainStats(
                submittedChunks: submittedChunks,
                submittedBytes: submittedBytes,
                droppedChunks: droppedChunks
            )
            lock.unlock()
            return stats
        }
    }

    private let stream: any AppleSpeechTranscriber
    private let tracker = ChunkTracker()
    private let logger: PipelineEventLogger
    private let runID: String
    private let language: String?
    private let sampleRate: Int
    private let startLock = NSLock()
    private var startTask: Task<Void, Error>?

    init(
        stream: any AppleSpeechTranscriber,
        logger: @escaping PipelineEventLogger,
        runID: String,
        language: String?,
        sampleRate: Int
    ) {
        self.stream = stream
        self.logger = logger
        self.runID = runID
        self.language = language
        self.sampleRate = sampleRate
    }

    func submit(chunk: Data) {
        guard !chunk.isEmpty else {
            return
        }
        let stream = self.stream
        let logger = self.logger
        let task = Task {
            do {
                try await ensureStarted()
                await stream.enqueueStreamingAudioChunk(chunk)
            } catch {
                logger("stt_stream_connect_failed", [
                    "error": error.localizedDescription,
                    "provider": STTProvider.appleSpeech.rawValue,
                ])
            }
        }
        tracker.submit(task, chunkSize: chunk.count)
    }

    func finish() async throws -> STTStreamingFinalizeResult {
        try await ensureStarted()
        let drainStartedAt = Date()
        let tasks = tracker.close()
        for task in tasks {
            await task.value
        }
        let stats = tracker.stats()
        let drainDoneAt = Date()
        logger("stt_stream_chunks_drained", [
            "request_sent_at_ms": epochMsString(drainStartedAt),
            "response_received_at_ms": epochMsString(drainDoneAt),
            "submitted_chunks": String(stats.submittedChunks),
            "submitted_bytes": String(stats.submittedBytes),
            "dropped_chunks": String(stats.droppedChunks),
            "provider": STTProvider.appleSpeech.rawValue,
        ])
        SystemLog.stt("app_stream_chunks_drained", fields: [
            "run": runID,
            "request_sent_at_ms": epochMsString(drainStartedAt),
            "response_received_at_ms": epochMsString(drainDoneAt),
            "submitted_chunks": String(stats.submittedChunks),
            "submitted_bytes": String(stats.submittedBytes),
            "dropped_chunks": String(stats.droppedChunks),
            "provider": STTProvider.appleSpeech.rawValue,
        ])

        let finalized = try await stream.finishStreaming()
        return STTStreamingFinalizeResult(
            transcript: finalized.transcript,
            usage: finalized.usage,
            drainStats: stats
        )
    }

    private func ensureStarted() async throws {
        let task = startTaskIfNeeded()
        try await task.value
    }

    private func startTaskIfNeeded() -> Task<Void, Error> {
        startLock.lock()
        if let existing = startTask {
            startLock.unlock()
            return existing
        }
        let stream = self.stream
        let language = self.language
        let sampleRate = self.sampleRate
        let logger = self.logger
        let created = Task {
            try await stream.startStreaming(
                sampleRate: sampleRate,
                language: language
            )
            logger("stt_stream_connected", [
                "sample_rate": String(sampleRate),
                "language": language ?? "auto",
                "provider": STTProvider.appleSpeech.rawValue,
            ])
        }
        startTask = created
        startLock.unlock()
        return created
    }
}

private final class OpenAIRealtimeSession: STTStreamingSession, @unchecked Sendable {
    private final class ChunkTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var pendingTasks: [Task<Void, Never>] = []
        private var closed = false
        private var submittedChunks = 0
        private var submittedBytes = 0
        private var droppedChunks = 0

        func submit(chunk: Data, stream: any OpenAIRealtimeStreamingTranscriber) {
            guard !chunk.isEmpty else { return }

            lock.lock()
            if closed {
                droppedChunks += 1
                lock.unlock()
                return
            }
            submittedChunks += 1
            submittedBytes += chunk.count
            let task = Task {
                await stream.enqueueAudioChunk(chunk)
            }
            pendingTasks.append(task)
            lock.unlock()
        }

        func close() -> [Task<Void, Never>] {
            lock.lock()
            closed = true
            let tasks = pendingTasks
            pendingTasks.removeAll(keepingCapacity: false)
            lock.unlock()
            return tasks
        }

        func stats() -> STTStreamingDrainStats {
            lock.lock()
            let stats = STTStreamingDrainStats(
                submittedChunks: submittedChunks,
                submittedBytes: submittedBytes,
                droppedChunks: droppedChunks
            )
            lock.unlock()
            return stats
        }
    }

    private let stream: any OpenAIRealtimeStreamingTranscriber
    private let tracker = ChunkTracker()
    private let logger: PipelineEventLogger
    private let runID: String

    init(stream: any OpenAIRealtimeStreamingTranscriber, logger: @escaping PipelineEventLogger, runID: String) {
        self.stream = stream
        self.logger = logger
        self.runID = runID
    }

    func submit(chunk: Data) {
        tracker.submit(chunk: chunk, stream: stream)
    }

    func finish() async throws -> STTStreamingFinalizeResult {
        let drainStartedAt = Date()
        let tasks = tracker.close()
        for task in tasks {
            await task.value
        }
        let stats = tracker.stats()
        let drainDoneAt = Date()
        logger("stt_stream_chunks_drained", [
            "request_sent_at_ms": epochMsString(drainStartedAt),
            "response_received_at_ms": epochMsString(drainDoneAt),
            "submitted_chunks": String(stats.submittedChunks),
            "submitted_bytes": String(stats.submittedBytes),
            "dropped_chunks": String(stats.droppedChunks),
            "provider": STTProvider.whisper.rawValue,
        ])
        SystemLog.stt("app_stream_chunks_drained", fields: [
            "run": runID,
            "request_sent_at_ms": epochMsString(drainStartedAt),
            "response_received_at_ms": epochMsString(drainDoneAt),
            "submitted_chunks": String(stats.submittedChunks),
            "submitted_bytes": String(stats.submittedBytes),
            "dropped_chunks": String(stats.droppedChunks),
            "provider": STTProvider.whisper.rawValue,
        ])

        let finalized = try await stream.finish()
        return STTStreamingFinalizeResult(
            transcript: finalized.transcript,
            usage: finalized.usage,
            drainStats: stats
        )
    }
}

private final class DeepgramLiveSession: STTStreamingSession, @unchecked Sendable {
    private final class ChunkTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var pendingTasks: [Task<Void, Never>] = []
        private var closed = false
        private var submittedChunks = 0
        private var submittedBytes = 0
        private var droppedChunks = 0

        func submit(chunk: Data, stream: DeepgramStreamingClient) {
            guard !chunk.isEmpty else { return }

            lock.lock()
            if closed {
                droppedChunks += 1
                lock.unlock()
                return
            }
            submittedChunks += 1
            submittedBytes += chunk.count
            let task = Task {
                await stream.enqueueAudioChunk(chunk)
            }
            pendingTasks.append(task)
            lock.unlock()
        }

        func close() -> [Task<Void, Never>] {
            lock.lock()
            closed = true
            let tasks = pendingTasks
            pendingTasks.removeAll(keepingCapacity: false)
            lock.unlock()
            return tasks
        }

        func stats() -> STTStreamingDrainStats {
            lock.lock()
            let stats = STTStreamingDrainStats(
                submittedChunks: submittedChunks,
                submittedBytes: submittedBytes,
                droppedChunks: droppedChunks
            )
            lock.unlock()
            return stats
        }
    }

    private let stream: DeepgramStreamingClient
    private let tracker = ChunkTracker()
    private let logger: PipelineEventLogger
    private let runID: String

    init(stream: DeepgramStreamingClient, logger: @escaping PipelineEventLogger, runID: String) {
        self.stream = stream
        self.logger = logger
        self.runID = runID
    }

    func submit(chunk: Data) {
        tracker.submit(chunk: chunk, stream: stream)
    }

    func finish() async throws -> STTStreamingFinalizeResult {
        let drainStartedAt = Date()
        let tasks = tracker.close()
        for task in tasks {
            await task.value
        }
        let stats = tracker.stats()
        let drainDoneAt = Date()
        logger("stt_stream_chunks_drained", [
            "request_sent_at_ms": epochMsString(drainStartedAt),
            "response_received_at_ms": epochMsString(drainDoneAt),
            "submitted_chunks": String(stats.submittedChunks),
            "submitted_bytes": String(stats.submittedBytes),
            "dropped_chunks": String(stats.droppedChunks),
        ])
        SystemLog.stt("app_stream_chunks_drained", fields: [
            "run": runID,
            "request_sent_at_ms": epochMsString(drainStartedAt),
            "response_received_at_ms": epochMsString(drainDoneAt),
            "submitted_chunks": String(stats.submittedChunks),
            "submitted_bytes": String(stats.submittedBytes),
            "dropped_chunks": String(stats.droppedChunks),
        ])

        let finalized = try await stream.finish()
        return STTStreamingFinalizeResult(
            transcript: finalized.transcript,
            usage: finalized.usage,
            drainStats: stats
        )
    }
}
