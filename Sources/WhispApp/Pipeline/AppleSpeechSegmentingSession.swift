import Foundation
import WhispCore

private func segmentEpochMsString(_ date: Date = Date()) -> String {
    WhispTime.epochMsString(date)
}

final class AppleSpeechSegmentingSession: STTStreamingSession, @unchecked Sendable {
    typealias SegmentCommitHandler = @Sendable (STTCommittedSegment) -> Void

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

    private final class ErrorStore: @unchecked Sendable {
        private let lock = NSLock()
        private var firstError: Error?

        func setIfNeeded(_ error: Error) {
            lock.lock()
            if firstError == nil {
                firstError = error
            }
            lock.unlock()
        }

        func current() -> Error? {
            lock.lock()
            let error = firstError
            lock.unlock()
            return error
        }
    }

    private final class OrderedExecutor: @unchecked Sendable {
        private let lock = NSLock()
        private var tailTask: Task<Void, Never>?

        func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
            lock.lock()
            let previous = tailTask
            let task = Task {
                if let previous {
                    await previous.value
                }
                await operation()
            }
            tailTask = task
            lock.unlock()
            return task
        }
    }

    private actor Worker {
        private let transcriber: any AppleSpeechTranscriber
        private let sampleRate: Int
        private let language: String?
        private let silenceMs: Int
        private let maxSegmentMs: Int
        private let preRollMs: Int
        private let preRollByteLimit: Int
        private let onSegmentCommitted: SegmentCommitHandler?
        private let logger: PipelineEventLogger

        private var preRollBuffer = Data()
        private var pendingPreRoll = Data()
        private var segmentStarted = false
        private var segmentHasSpeech = false
        private var segmentStartMs: Int64 = 0
        private var segmentDurationMs = 0

        private var timelineMs: Int64 = 0
        private var silenceAccumulatedMs = 0

        private var activeVADKind: String?
        private var activeVADStartMs: Int64 = 0

        private var committedSegments: [STTCommittedSegment] = []
        private var committedVADIntervals: [VADInterval] = []

        init(
            transcriber: any AppleSpeechTranscriber,
            sampleRate: Int,
            language: String?,
            segmentation: STTSegmentationConfig,
            logger: @escaping PipelineEventLogger,
            onSegmentCommitted: SegmentCommitHandler?
        ) {
            self.transcriber = transcriber
            self.sampleRate = max(sampleRate, 1)
            self.language = language
            silenceMs = max(segmentation.silenceMs, 1)
            maxSegmentMs = max(segmentation.maxSegmentMs, 1)
            preRollMs = max(segmentation.preRollMs, 0)
            preRollByteLimit = max(0, (self.sampleRate * preRollMs / 1_000) * MemoryLayout<Int16>.size)
            self.logger = logger
            self.onSegmentCommitted = onSegmentCommitted
        }

        func process(chunk: Data) async throws {
            guard !chunk.isEmpty else {
                return
            }

            let chunkDurationMs = max(1, durationMs(forByteCount: chunk.count))
            let chunkStartMs = timelineMs
            timelineMs += Int64(chunkDurationMs)

            appendToPreRoll(chunk)
            try await ensureSegmentStarted()
            await transcriber.enqueueStreamingAudioChunk(chunk)

            segmentDurationMs += chunkDurationMs

            let isSpeech = Self.isSpeechChunk(chunk)
            updateVAD(kind: isSpeech ? "speech" : "silence", startMs: chunkStartMs)
            if isSpeech {
                segmentHasSpeech = true
                silenceAccumulatedMs = 0
            } else {
                silenceAccumulatedMs += chunkDurationMs
            }

            if segmentDurationMs >= maxSegmentMs {
                try await commitCurrentSegment(reason: "max_segment", endMs: timelineMs)
                return
            }

            if !isSpeech,
               segmentHasSpeech,
               silenceAccumulatedMs >= silenceMs
            {
                try await commitCurrentSegment(reason: "silence", endMs: timelineMs)
            }
        }

        func finish() async throws -> (
            transcript: String,
            usage: STTUsage?,
            segments: [STTCommittedSegment],
            vadIntervals: [VADInterval]
        ) {
            if segmentStarted {
                try await commitCurrentSegment(reason: "stop", endMs: timelineMs)
            }
            closeActiveVAD(endMs: timelineMs)

            let transcript = committedSegments
                .map(\.text)
                .joined(separator: "\n")
            let usage: STTUsage?
            if timelineMs > 0 {
                usage = STTUsage(
                    durationSeconds: Double(timelineMs) / 1_000,
                    requestID: nil,
                    provider: STTProvider.appleSpeech.rawValue
                )
            } else {
                usage = nil
            }
            return (transcript, usage, committedSegments, committedVADIntervals)
        }

        private func ensureSegmentStarted() async throws {
            guard !segmentStarted else {
                return
            }

            try await transcriber.startStreaming(sampleRate: sampleRate, language: language)
            logger("stt_stream_connected", [
                "sample_rate": String(sampleRate),
                "language": language ?? "auto",
                "provider": STTProvider.appleSpeech.rawValue,
            ])
            let rewind = Int64(min(preRollMs, Int(timelineMs)))
            segmentStartMs = max(0, timelineMs - rewind)
            segmentStarted = true
            segmentHasSpeech = false
            segmentDurationMs = 0
            silenceAccumulatedMs = 0

            if !pendingPreRoll.isEmpty {
                await transcriber.enqueueStreamingAudioChunk(pendingPreRoll)
                pendingPreRoll.removeAll(keepingCapacity: false)
            }
        }

        private func commitCurrentSegment(reason: String, endMs: Int64) async throws {
            guard segmentStarted else {
                return
            }

            let finalized = try await transcriber.finishStreaming()
            segmentStarted = false
            pendingPreRoll = preRollBuffer

            let trimmed = finalized.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let segment = STTCommittedSegment(
                    index: committedSegments.count,
                    startMs: segmentStartMs,
                    endMs: max(segmentStartMs, endMs),
                    text: trimmed,
                    reason: reason
                )
                committedSegments.append(segment)
                onSegmentCommitted?(segment)
                logger("stt_segment_committed", [
                    "reason": reason,
                    "index": String(segment.index),
                    "start_ms": String(segment.startMs),
                    "end_ms": String(segment.endMs),
                    "text_chars": String(segment.text.count),
                ])
            }

            segmentHasSpeech = false
            segmentDurationMs = 0
            silenceAccumulatedMs = 0
        }

        private func appendToPreRoll(_ chunk: Data) {
            guard preRollByteLimit > 0 else {
                return
            }
            preRollBuffer.append(chunk)
            if preRollBuffer.count > preRollByteLimit {
                preRollBuffer = Data(preRollBuffer.suffix(preRollByteLimit))
            }
        }

        private func updateVAD(kind: String, startMs: Int64) {
            if activeVADKind == kind {
                return
            }

            if let activeVADKind {
                let interval = VADInterval(
                    startMs: activeVADStartMs,
                    endMs: startMs,
                    kind: activeVADKind
                )
                if interval.endMs > interval.startMs {
                    committedVADIntervals.append(interval)
                }
            }

            activeVADKind = kind
            activeVADStartMs = startMs
        }

        private func closeActiveVAD(endMs: Int64) {
            guard let currentKind = activeVADKind else {
                return
            }
            let interval = VADInterval(
                startMs: activeVADStartMs,
                endMs: endMs,
                kind: currentKind
            )
            if interval.endMs > interval.startMs {
                committedVADIntervals.append(interval)
            }
            activeVADKind = nil
        }

        private func durationMs(forByteCount byteCount: Int) -> Int {
            guard byteCount > 0 else {
                return 0
            }
            let sampleCount = byteCount / MemoryLayout<Int16>.size
            guard sampleCount > 0 else {
                return 0
            }
            return max(1, Int((Double(sampleCount) / Double(sampleRate)) * 1_000))
        }

        private static func isSpeechChunk(_ chunk: Data) -> Bool {
            guard !chunk.isEmpty else {
                return false
            }

            var sumSquares = 0.0
            var count = 0
            chunk.withUnsafeBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Int16.self)
                for sample in samples {
                    let normalized = Double(sample) / 32_768.0
                    sumSquares += normalized * normalized
                    count += 1
                }
            }

            guard count > 0 else {
                return false
            }

            let rms = sqrt(sumSquares / Double(count))
            return rms >= 0.015
        }
    }

    private let tracker = ChunkTracker()
    private let orderedExecutor = OrderedExecutor()
    private let worker: Worker
    private let errorStore = ErrorStore()
    private let logger: PipelineEventLogger
    private let runID: String

    init(
        transcriber: any AppleSpeechTranscriber,
        sampleRate: Int,
        language: String?,
        segmentation: STTSegmentationConfig,
        logger: @escaping PipelineEventLogger,
        runID: String,
        onSegmentCommitted: SegmentCommitHandler?
    ) {
        worker = Worker(
            transcriber: transcriber,
            sampleRate: sampleRate,
            language: language,
            segmentation: segmentation,
            logger: logger,
            onSegmentCommitted: onSegmentCommitted
        )
        self.logger = logger
        self.runID = runID
    }

    func submit(chunk: Data) {
        guard !chunk.isEmpty else {
            return
        }

        let worker = self.worker
        let errorStore = self.errorStore
        let task = orderedExecutor.enqueue {
            do {
                try await worker.process(chunk: chunk)
            } catch {
                errorStore.setIfNeeded(error)
            }
        }
        tracker.submit(task, chunkSize: chunk.count)
    }

    func finish() async throws -> STTStreamingFinalizeResult {
        let drainStartedAt = Date()
        let tasks = tracker.close()
        for task in tasks {
            await task.value
        }
        if let error = errorStore.current() {
            throw error
        }

        let stats = tracker.stats()
        let drainDoneAt = Date()
        logger("stt_stream_chunks_drained", [
            "request_sent_at_ms": segmentEpochMsString(drainStartedAt),
            "response_received_at_ms": segmentEpochMsString(drainDoneAt),
            "submitted_chunks": String(stats.submittedChunks),
            "submitted_bytes": String(stats.submittedBytes),
            "dropped_chunks": String(stats.droppedChunks),
            "provider": STTProvider.appleSpeech.rawValue,
        ])
        SystemLog.stt("app_stream_chunks_drained", fields: [
            "run": runID,
            "request_sent_at_ms": segmentEpochMsString(drainStartedAt),
            "response_received_at_ms": segmentEpochMsString(drainDoneAt),
            "submitted_chunks": String(stats.submittedChunks),
            "submitted_bytes": String(stats.submittedBytes),
            "dropped_chunks": String(stats.droppedChunks),
            "provider": STTProvider.appleSpeech.rawValue,
        ])

        let result = try await worker.finish()
        return STTStreamingFinalizeResult(
            transcript: result.transcript,
            usage: result.usage,
            drainStats: stats,
            segments: result.segments,
            vadIntervals: result.vadIntervals
        )
    }
}
