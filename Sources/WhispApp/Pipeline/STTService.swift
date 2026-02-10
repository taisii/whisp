import Foundation
import WhispCore

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
            logger("stt_stream_finalize_start", [:])
            do {
                let result = try await streamingSession.finish()
                logger("stt_stream_finalize_done", [
                    "duration_ms": msString(elapsedMs(since: streamFinalizeStartedAt)),
                    "text_chars": String(result.transcript.count),
                ])
                return STTTranscriptionResult(transcript: result.transcript, usage: result.usage)
            } catch {
                logger("stt_stream_failed_fallback_rest", [
                    "error": error.localizedDescription,
                ])
                let sttStartedAt = DispatchTime.now()
                let stt = try await restClient.transcribe(
                    apiKey: deepgramKey,
                    sampleRate: recording.sampleRate,
                    audio: recording.pcmData,
                    language: language
                )
                logger("stt_done", [
                    "source": "rest_fallback",
                    "duration_ms": msString(elapsedMs(since: sttStartedAt)),
                    "text_chars": String(stt.transcript.count),
                ])
                return STTTranscriptionResult(transcript: stt.transcript, usage: stt.usage)
            }
        }

        let sttStartedAt = DispatchTime.now()
        logger("stt_start", [
            "sample_rate": String(recording.sampleRate),
            "audio_bytes": String(recording.pcmData.count),
        ])
        let stt = try await restClient.transcribe(
            apiKey: deepgramKey,
            sampleRate: recording.sampleRate,
            audio: recording.pcmData,
            language: language
        )
        logger("stt_done", [
            "source": "rest",
            "duration_ms": msString(elapsedMs(since: sttStartedAt)),
            "text_chars": String(stt.transcript.count),
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
        logger("stt_stream_chunks_drained", [
            "duration_ms": msString(drainMs),
            "submitted_chunks": String(stats.submittedChunks),
            "submitted_bytes": String(stats.submittedBytes),
            "dropped_chunks": String(stats.droppedChunks),
        ])
        SystemLog.stt("app_stream_chunks_drained", fields: [
            "run": runID,
            "duration_ms": msString(drainMs),
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
