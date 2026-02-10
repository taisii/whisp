import Foundation
import WhispCore

private func epochMsString(_ date: Date = Date()) -> String {
    String(format: "%.3f", date.timeIntervalSince1970 * 1000)
}

protocol STTStreamingSession: AnyObject, Sendable {
    func submit(chunk: Data)
    func finish() async throws -> (transcript: String, usage: STTUsage?)
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
                logger(DebugRunEventName.sttStreamConnected.rawValue, [
                    DebugRunEventField.sampleRate.rawValue: String(AudioRecorder.targetSampleRate),
                    "language": language ?? "auto",
                ])
            } catch {
                logger(DebugRunEventName.sttStreamConnectFailed.rawValue, [
                    DebugRunEventField.error.rawValue: error.localizedDescription,
                ])
            }
        }
        return session
    }

    func transcribe(
        config: Config,
        recording: RecordingResult,
        language: String?,
        runID: String,
        streamingSession: (any STTStreamingSession)?,
        logger: @escaping PipelineEventLogger
    ) async throws -> STTTranscriptionResult {
        let deepgramKey = config.apiKeys.deepgram.trimmingCharacters(in: .whitespacesAndNewlines)
        if deepgramKey.isEmpty {
            throw AppError.invalidArgument("Deepgram APIキーが未設定です")
        }

        if let streamingSession {
            let streamFinalizeStartedAt = DispatchTime.now()
            let finalizeRequestedAt = Date()
            logger(DebugRunEventName.sttStreamFinalizeStart.rawValue, [
                DebugRunEventField.requestSentAtMs.rawValue: epochMsString(finalizeRequestedAt),
            ])
            do {
                let result = try await streamingSession.finish()
                let finalizeResponseAt = Date()
                logger(DebugRunEventName.sttStreamFinalizeDone.rawValue, [
                    DebugRunEventField.durationMs.rawValue: msString(elapsedMs(since: streamFinalizeStartedAt)),
                    DebugRunEventField.requestSentAtMs.rawValue: epochMsString(finalizeRequestedAt),
                    DebugRunEventField.responseReceivedAtMs.rawValue: epochMsString(finalizeResponseAt),
                    DebugRunEventField.textChars.rawValue: String(result.transcript.count),
                ])
                return STTTranscriptionResult(transcript: result.transcript, usage: result.usage)
            } catch {
                logger(DebugRunEventName.sttStreamFailedFallbackREST.rawValue, [
                    DebugRunEventField.error.rawValue: error.localizedDescription,
                ])
                let sttStartedAt = DispatchTime.now()
                let restRequestedAt = Date()
                logger(DebugRunEventName.sttStart.rawValue, [
                    DebugRunEventField.source.rawValue: DebugSTTSource.restFallback.rawValue,
                    DebugRunEventField.sampleRate.rawValue: String(recording.sampleRate),
                    DebugRunEventField.audioBytes.rawValue: String(recording.pcmData.count),
                    DebugRunEventField.requestSentAtMs.rawValue: epochMsString(restRequestedAt),
                ])
                let stt = try await restClient.transcribe(
                    apiKey: deepgramKey,
                    sampleRate: recording.sampleRate,
                    audio: recording.pcmData,
                    language: language
                )
                let restResponseAt = Date()
                logger(DebugRunEventName.sttDone.rawValue, [
                    DebugRunEventField.source.rawValue: DebugSTTSource.restFallback.rawValue,
                    DebugRunEventField.durationMs.rawValue: msString(elapsedMs(since: sttStartedAt)),
                    DebugRunEventField.requestSentAtMs.rawValue: epochMsString(restRequestedAt),
                    DebugRunEventField.responseReceivedAtMs.rawValue: epochMsString(restResponseAt),
                    DebugRunEventField.textChars.rawValue: String(stt.transcript.count),
                ])
                return STTTranscriptionResult(transcript: stt.transcript, usage: stt.usage)
            }
        }

        let sttStartedAt = DispatchTime.now()
        let restRequestedAt = Date()
        logger(DebugRunEventName.sttStart.rawValue, [
            DebugRunEventField.sampleRate.rawValue: String(recording.sampleRate),
            DebugRunEventField.audioBytes.rawValue: String(recording.pcmData.count),
            DebugRunEventField.requestSentAtMs.rawValue: epochMsString(restRequestedAt),
        ])
        let stt = try await restClient.transcribe(
            apiKey: deepgramKey,
            sampleRate: recording.sampleRate,
            audio: recording.pcmData,
            language: language
        )
        let restResponseAt = Date()
        logger(DebugRunEventName.sttDone.rawValue, [
            DebugRunEventField.source.rawValue: DebugSTTSource.rest.rawValue,
            DebugRunEventField.durationMs.rawValue: msString(elapsedMs(since: sttStartedAt)),
            DebugRunEventField.requestSentAtMs.rawValue: epochMsString(restRequestedAt),
            DebugRunEventField.responseReceivedAtMs.rawValue: epochMsString(restResponseAt),
            DebugRunEventField.textChars.rawValue: String(stt.transcript.count),
        ])
        return STTTranscriptionResult(transcript: stt.transcript, usage: stt.usage)
    }

    private func elapsedMs(since start: DispatchTime, to end: DispatchTime = .now()) -> Double {
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000
    }

    private func msString(_ value: Double) -> String {
        String(format: "%.1f", value)
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
        return nil
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

        let sttStartedAt = DispatchTime.now()
        let requestSentAt = Date()
        logger(DebugRunEventName.sttStart.rawValue, [
            DebugRunEventField.sampleRate.rawValue: String(recording.sampleRate),
            DebugRunEventField.audioBytes.rawValue: String(recording.pcmData.count),
            DebugRunEventField.source.rawValue: DebugSTTSource.whisper.rawValue,
            DebugRunEventField.requestSentAtMs.rawValue: epochMsString(requestSentAt),
        ])
        let stt = try await client.transcribe(
            apiKey: openAIKey,
            sampleRate: recording.sampleRate,
            audio: recording.pcmData,
            language: language
        )
        let responseReceivedAt = Date()
        logger(DebugRunEventName.sttDone.rawValue, [
            DebugRunEventField.source.rawValue: DebugSTTSource.whisperREST.rawValue,
            DebugRunEventField.durationMs.rawValue: msString(elapsedMs(since: sttStartedAt)),
            DebugRunEventField.requestSentAtMs.rawValue: epochMsString(requestSentAt),
            DebugRunEventField.responseReceivedAtMs.rawValue: epochMsString(responseReceivedAt),
            DebugRunEventField.textChars.rawValue: String(stt.transcript.count),
        ])
        return STTTranscriptionResult(transcript: stt.transcript, usage: stt.usage)
    }

    private func elapsedMs(since start: DispatchTime, to end: DispatchTime = .now()) -> Double {
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000
    }

    private func msString(_ value: Double) -> String {
        String(format: "%.1f", value)
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
        let sttStartedAt = DispatchTime.now()
        let requestSentAt = Date()
        logger(DebugRunEventName.sttStart.rawValue, [
            DebugRunEventField.sampleRate.rawValue: String(recording.sampleRate),
            DebugRunEventField.audioBytes.rawValue: String(recording.pcmData.count),
            DebugRunEventField.source.rawValue: DebugSTTSource.appleSpeech.rawValue,
            DebugRunEventField.requestSentAtMs.rawValue: epochMsString(requestSentAt),
        ])
        let stt = try await client.transcribe(
            sampleRate: recording.sampleRate,
            audio: recording.pcmData,
            language: language
        )
        let responseReceivedAt = Date()
        logger(DebugRunEventName.sttDone.rawValue, [
            DebugRunEventField.source.rawValue: DebugSTTSource.appleSpeech.rawValue,
            DebugRunEventField.durationMs.rawValue: msString(elapsedMs(since: sttStartedAt)),
            DebugRunEventField.requestSentAtMs.rawValue: epochMsString(requestSentAt),
            DebugRunEventField.responseReceivedAtMs.rawValue: epochMsString(responseReceivedAt),
            DebugRunEventField.textChars.rawValue: String(stt.transcript.count),
        ])
        return STTTranscriptionResult(transcript: stt.transcript, usage: stt.usage)
    }

    private func elapsedMs(since start: DispatchTime, to end: DispatchTime = .now()) -> Double {
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000
    }

    private func msString(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

private final class DeepgramLiveSession: STTStreamingSession, @unchecked Sendable {
    private final class ChunkTracker: @unchecked Sendable {
        struct DrainStats {
            let submittedChunks: Int
            let submittedBytes: Int
            let droppedChunks: Int
        }

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

        func stats() -> DrainStats {
            lock.lock()
            let stats = DrainStats(
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

    func finish() async throws -> (transcript: String, usage: STTUsage?) {
        let drainStartedAt = DispatchTime.now()
        let tasks = tracker.close()
        for task in tasks {
            await task.value
        }
        let stats = tracker.stats()
        let drainMs = elapsedMs(since: drainStartedAt)
        logger(DebugRunEventName.sttStreamChunksDrained.rawValue, [
            DebugRunEventField.durationMs.rawValue: msString(drainMs),
            "submitted_chunks": String(stats.submittedChunks),
            "submitted_bytes": String(stats.submittedBytes),
            "dropped_chunks": String(stats.droppedChunks),
        ])
        SystemLog.stt("app_stream_chunks_drained", fields: [
            "run": runID,
            DebugRunEventField.durationMs.rawValue: msString(drainMs),
            "submitted_chunks": String(stats.submittedChunks),
            "submitted_bytes": String(stats.submittedBytes),
            "dropped_chunks": String(stats.droppedChunks),
        ])

        return try await stream.finish()
    }

    private func elapsedMs(since start: DispatchTime, to end: DispatchTime = .now()) -> Double {
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000
    }

    private func msString(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
