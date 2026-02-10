import Foundation
import WhispCore

private func epochMsString(_ date: Date = Date()) -> String {
    String(format: "%.3f", date.timeIntervalSince1970 * 1000)
}

private func epochMs(_ date: Date = Date()) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
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
        logger: @escaping PipelineEventLogger
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
        logger: @escaping PipelineEventLogger
    ) -> (any STTStreamingSession)? {
        service(for: config.sttProvider).startStreamingSessionIfNeeded(
            config: config,
            runID: runID,
            language: language,
            logger: logger
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
        try await service(for: config.sttProvider).transcribe(
            config: config,
            recording: recording,
            language: language,
            runID: runID,
            streamingSession: streamingSession,
            logger: logger
        )
    }

    private func service(for provider: STTProvider) -> any STTService {
        switch provider {
        case .deepgram:
            return deepgramService
        case .whisper:
            return whisperService
        case .appleSpeech:
            return appleSpeechService
        }
    }
}

final class DeepgramSTTService: STTService, @unchecked Sendable {
    private let restClient: DeepgramClient

    init(restClient: DeepgramClient = DeepgramClient()) {
        self.restClient = restClient
    }

    func startStreamingSessionIfNeeded(
        config: Config,
        runID: String,
        language: String?,
        logger: @escaping PipelineEventLogger
    ) -> (any STTStreamingSession)? {
        guard !config.llmModel.usesDirectAudio else {
            return nil
        }
        let deepgramKey = config.apiKeys.deepgram.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deepgramKey.isEmpty else {
            return nil
        }

        let stream = DeepgramStreamingClient()
        let session = DeepgramLiveSession(stream: stream, logger: logger, runID: runID)
        Task {
            do {
                try await stream.start(
                    apiKey: deepgramKey,
                    sampleRate: AudioRecorder.targetSampleRate,
                    language: language
                )
                logger("stt_stream_connected", [
                    "sample_rate": String(AudioRecorder.targetSampleRate),
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
        let deepgramKey = config.apiKeys.deepgram.trimmingCharacters(in: .whitespacesAndNewlines)
        if deepgramKey.isEmpty {
            throw AppError.invalidArgument("Deepgram APIキーが未設定です")
        }

        if let streamingSession {
            let finalizeRequestedAt = Date()
            let finalizeRequestedAtMs = epochMs(finalizeRequestedAt)
            logger("stt_stream_finalize_start", [
                "request_sent_at_ms": epochMsString(finalizeRequestedAt),
            ])

            do {
                let result = try await streamingSession.finish()
                let finalizeResponseAt = Date()
                let finalizeResponseAtMs = epochMs(finalizeResponseAt)
                logger("stt_stream_finalize_done", [
                    "request_sent_at_ms": epochMsString(finalizeRequestedAt),
                    "response_received_at_ms": epochMsString(finalizeResponseAt),
                    "text_chars": String(result.transcript.count),
                ])

                let attempt = DebugSTTAttempt(
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

                let trace = STTTrace(
                    provider: config.sttProvider.rawValue,
                    route: .streaming,
                    mainSpan: STTMainSpanTrace(
                        eventStartMs: finalizeRequestedAtMs,
                        eventEndMs: finalizeResponseAtMs,
                        status: .ok,
                        source: "stream_finalize",
                        textChars: result.transcript.count,
                        sampleRate: recording.sampleRate,
                        audioBytes: recording.pcmData.count,
                        error: nil
                    ),
                    attempts: [attempt]
                )
                return STTTranscriptionResult(transcript: result.transcript, usage: result.usage, trace: trace)
            } catch {
                logger("stt_stream_failed_fallback_rest", [
                    "error": error.localizedDescription,
                ])

                let failedFinalizeAttempt = DebugSTTAttempt(
                    kind: .streamFinalize,
                    status: .error,
                    eventStartMs: finalizeRequestedAtMs,
                    eventEndMs: epochMs(),
                    source: "stream_finalize",
                    error: error.localizedDescription,
                    sampleRate: recording.sampleRate,
                    audioBytes: recording.pcmData.count
                )

                let restRequestedAt = Date()
                let restRequestedAtMs = epochMs(restRequestedAt)
                logger("stt_start", [
                    "source": "rest_fallback",
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
                    "source": "rest_fallback",
                    "request_sent_at_ms": epochMsString(restRequestedAt),
                    "response_received_at_ms": epochMsString(restResponseAt),
                    "text_chars": String(stt.transcript.count),
                ])

                let restAttempt = DebugSTTAttempt(
                    kind: .restFallback,
                    status: .ok,
                    eventStartMs: restRequestedAtMs,
                    eventEndMs: restResponseAtMs,
                    source: "rest_fallback",
                    textChars: stt.transcript.count,
                    sampleRate: recording.sampleRate,
                    audioBytes: recording.pcmData.count
                )

                let trace = STTTrace(
                    provider: config.sttProvider.rawValue,
                    route: .streamingFallbackREST,
                    mainSpan: STTMainSpanTrace(
                        eventStartMs: finalizeRequestedAtMs,
                        eventEndMs: restResponseAtMs,
                        status: .ok,
                        source: "rest_fallback",
                        textChars: stt.transcript.count,
                        sampleRate: recording.sampleRate,
                        audioBytes: recording.pcmData.count,
                        error: nil
                    ),
                    attempts: [failedFinalizeAttempt, restAttempt]
                )
                return STTTranscriptionResult(transcript: stt.transcript, usage: stt.usage, trace: trace)
            }
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

        let attempt = DebugSTTAttempt(
            kind: .rest,
            status: .ok,
            eventStartMs: restRequestedAtMs,
            eventEndMs: restResponseAtMs,
            source: "rest",
            textChars: stt.transcript.count,
            sampleRate: recording.sampleRate,
            audioBytes: recording.pcmData.count
        )
        let trace = STTTrace(
            provider: config.sttProvider.rawValue,
            route: .rest,
            mainSpan: STTMainSpanTrace(
                eventStartMs: restRequestedAtMs,
                eventEndMs: restResponseAtMs,
                status: .ok,
                source: "rest",
                textChars: stt.transcript.count,
                sampleRate: recording.sampleRate,
                audioBytes: recording.pcmData.count,
                error: nil
            ),
            attempts: [attempt]
        )
        return STTTranscriptionResult(transcript: stt.transcript, usage: stt.usage, trace: trace)
    }
}

final class WhisperSTTService: STTService, @unchecked Sendable {
    private let client: WhisperClient

    init(client: WhisperClient = WhisperClient()) {
        self.client = client
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
        config: Config,
        recording: RecordingResult,
        language: String?,
        runID _: String,
        streamingSession _: (any STTStreamingSession)?,
        logger: @escaping PipelineEventLogger
    ) async throws -> STTTranscriptionResult {
        let openAIKey = config.apiKeys.openai.trimmingCharacters(in: .whitespacesAndNewlines)
        if openAIKey.isEmpty {
            throw AppError.invalidArgument("OpenAI APIキーが未設定です（Whisper STT）")
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

        let attempt = DebugSTTAttempt(
            kind: .whisperREST,
            status: .ok,
            eventStartMs: requestSentAtMs,
            eventEndMs: responseReceivedAtMs,
            source: "whisper_rest",
            textChars: stt.transcript.count,
            sampleRate: recording.sampleRate,
            audioBytes: recording.pcmData.count
        )
        let trace = STTTrace(
            provider: config.sttProvider.rawValue,
            route: .rest,
            mainSpan: STTMainSpanTrace(
                eventStartMs: requestSentAtMs,
                eventEndMs: responseReceivedAtMs,
                status: .ok,
                source: "whisper_rest",
                textChars: stt.transcript.count,
                sampleRate: recording.sampleRate,
                audioBytes: recording.pcmData.count,
                error: nil
            ),
            attempts: [attempt]
        )
        return STTTranscriptionResult(transcript: stt.transcript, usage: stt.usage, trace: trace)
    }
}

final class AppleSpeechSTTService: STTService, @unchecked Sendable {
    private let client: AppleSpeechClient

    init(client: AppleSpeechClient = AppleSpeechClient()) {
        self.client = client
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
        recording: RecordingResult,
        language: String?,
        runID _: String,
        streamingSession _: (any STTStreamingSession)?,
        logger: @escaping PipelineEventLogger
    ) async throws -> STTTranscriptionResult {
        let requestSentAt = Date()
        let requestSentAtMs = epochMs(requestSentAt)
        logger("stt_start", [
            "source": "apple_speech",
            "sample_rate": String(recording.sampleRate),
            "audio_bytes": String(recording.pcmData.count),
            "request_sent_at_ms": epochMsString(requestSentAt),
        ])
        let stt = try await client.transcribe(
            sampleRate: recording.sampleRate,
            audio: recording.pcmData,
            language: language
        )
        let responseReceivedAt = Date()
        let responseReceivedAtMs = epochMs(responseReceivedAt)
        logger("stt_done", [
            "source": "apple_speech",
            "request_sent_at_ms": epochMsString(requestSentAt),
            "response_received_at_ms": epochMsString(responseReceivedAt),
            "text_chars": String(stt.transcript.count),
        ])

        let attempt = DebugSTTAttempt(
            kind: .appleSpeech,
            status: .ok,
            eventStartMs: requestSentAtMs,
            eventEndMs: responseReceivedAtMs,
            source: "apple_speech",
            textChars: stt.transcript.count,
            sampleRate: recording.sampleRate,
            audioBytes: recording.pcmData.count
        )
        let trace = STTTrace(
            provider: STTProvider.appleSpeech.rawValue,
            route: .onDevice,
            mainSpan: STTMainSpanTrace(
                eventStartMs: requestSentAtMs,
                eventEndMs: responseReceivedAtMs,
                status: .ok,
                source: "apple_speech",
                textChars: stt.transcript.count,
                sampleRate: recording.sampleRate,
                audioBytes: recording.pcmData.count,
                error: nil
            ),
            attempts: [attempt]
        )
        return STTTranscriptionResult(transcript: stt.transcript, usage: stt.usage, trace: trace)
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
