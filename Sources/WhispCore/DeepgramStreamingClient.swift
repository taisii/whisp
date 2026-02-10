import Foundation

public actor DeepgramStreamingClient {
    private let session: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var started = false
    private var ready = false
    private var pendingChunks: [Data] = []

    private var finalSegments: [String] = []
    private var partial = ""
    private var duration: Double = 0
    private var sampleRate: Int = 16_000
    private var sentPCMBytes: Int = 0
    private var messageCount = 0
    private var lastMessageAt: DispatchTime = .now()
    private var requestID: String?
    private var sendError: String?
    private var finalChunkCount = 0
    private var metadataEventCount = 0
    private var speechFinalCount = 0

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func start(apiKey: String, sampleRate: Int, language: String?) async throws {
        guard !started else {
            return
        }

        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "punctuate", value: "false"),
        ]
        if let language {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw AppError.invalidArgument("Deepgram streaming URL生成に失敗")
        }

        var request = URLRequest(url: url)
        request.addValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        task.resume()

        webSocketTask = task
        started = true
        ready = false
        pendingChunks.removeAll(keepingCapacity: false)
        finalSegments.removeAll(keepingCapacity: false)
        partial = ""
        duration = 0
        self.sampleRate = max(1, sampleRate)
        sentPCMBytes = 0
        messageCount = 0
        lastMessageAt = .now()
        requestID = nil
        sendError = nil
        finalChunkCount = 0
        metadataEventCount = 0
        speechFinalCount = 0

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        // Allow handshake to settle before first send.
        try? await Task.sleep(nanoseconds: 120_000_000)
        ready = true
        await flushPendingChunks()
    }

    public func enqueueAudioChunk(_ chunk: Data) async {
        guard started else { return }
        guard !chunk.isEmpty else { return }

        if !ready {
            pendingChunks.append(chunk)
            return
        }
        await sendChunk(chunk)
    }

    public func finish() async throws -> (transcript: String, usage: STTUsage?) {
        guard started else {
            throw AppError.io("Deepgram streaming is not started")
        }

        await flushPendingChunks()
        let messagesBeforeFinalize = messageCount
        let finalsBeforeFinalize = finalChunkCount
        let metadataBeforeFinalize = metadataEventCount
        let speechFinalBeforeFinalize = speechFinalCount
        let hadTranscriptBeforeFinalize = !finalSegments.isEmpty || !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let finalizeStartedAt = DispatchTime.now()

        SystemLog.stt("stream_finalize_start", fields: [
            "messages_before": String(messagesBeforeFinalize),
            "finals_before": String(finalsBeforeFinalize),
            "speech_finals_before": String(speechFinalBeforeFinalize),
            "had_text": String(hadTranscriptBeforeFinalize),
            "pending_chunks": String(pendingChunks.count),
        ])

        if let socket = webSocketTask {
            do {
                try await socket.send(.string("{\"type\":\"Finalize\"}"))
            } catch {
                sendError = error.localizedDescription
            }
        }
        await waitForFinalizeDrain(
            messagesBeforeFinalize: messagesBeforeFinalize,
            finalsBeforeFinalize: finalsBeforeFinalize,
            metadataBeforeFinalize: metadataBeforeFinalize,
            speechFinalBeforeFinalize: speechFinalBeforeFinalize,
            hadTranscriptBeforeFinalize: hadTranscriptBeforeFinalize
        )

        let messagesBeforeClose = messageCount
        if let socket = webSocketTask {
            do {
                try await socket.send(.string("{\"type\":\"CloseStream\"}"))
            } catch {
                sendError = error.localizedDescription
            }
        }
        await waitForPostCloseDrain(messagesBeforeClose: messagesBeforeClose)

        let currentReceiveTask = receiveTask
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        if let currentReceiveTask {
            _ = await currentReceiveTask.result
        }

        SystemLog.stt("stream_finalize_done", fields: [
            "duration_ms": msString(elapsedMs(since: finalizeStartedAt)),
            "messages_total": String(messageCount),
            "finals_total": String(finalChunkCount),
            "speech_finals_total": String(speechFinalCount),
            "partial_chars": String(partial.count),
        ])

        started = false
        ready = false
        webSocketTask = nil
        self.receiveTask = nil

        var transcript = finalSegments.joined(separator: " ")
        if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !transcript.isEmpty {
                transcript.append(" ")
            }
            transcript.append(partial)
        }
        transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if transcript.isEmpty, let sendError {
            throw AppError.io("Deepgram streaming send failed: \(sendError)")
        }

        let estimatedDuration = estimateDurationSeconds()
        let usageDuration = estimatedDuration > 0 ? estimatedDuration : duration
        let usage: STTUsage? = usageDuration > 0
            ? STTUsage(
                durationSeconds: usageDuration,
                requestID: requestID,
                provider: STTProvider.deepgram.rawValue
            )
            : nil

        return (transcript, usage)
    }

    private func waitForFinalizeDrain(
        messagesBeforeFinalize: Int,
        finalsBeforeFinalize: Int,
        metadataBeforeFinalize: Int,
        speechFinalBeforeFinalize: Int,
        hadTranscriptBeforeFinalize: Bool
    ) async {
        let startedAt = DispatchTime.now()
        let minWaitMs = hadTranscriptBeforeFinalize ? 200.0 : 500.0
        let maxWaitMs = hadTranscriptBeforeFinalize ? 3000.0 : 4800.0
        let noMessageGraceMs = hadTranscriptBeforeFinalize ? 900.0 : 1800.0
        let idleAfterMessageMs = hadTranscriptBeforeFinalize ? 450.0 : 700.0

        while true {
            let waitedMs = elapsedMs(since: startedAt)
            if waitedMs >= maxWaitMs {
                return
            }

            if waitedMs < minWaitMs {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }

            if messageCount > messagesBeforeFinalize {
                let idleMs = elapsedMs(since: lastMessageAt)
                let gotNewMetadata = metadataEventCount > metadataBeforeFinalize
                let gotNewFinal = finalChunkCount > finalsBeforeFinalize
                let gotSpeechFinal = speechFinalCount > speechFinalBeforeFinalize
                if gotSpeechFinal, idleMs >= 220.0 {
                    return
                }
                if gotNewMetadata, idleMs >= 260.0 {
                    return
                }
                if idleMs >= idleAfterMessageMs, waitedMs >= noMessageGraceMs, gotNewFinal {
                    return
                }
                if idleMs >= idleAfterMessageMs, waitedMs >= noMessageGraceMs, !gotNewFinal {
                    return
                }
            } else if waitedMs >= noMessageGraceMs {
                return
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func waitForPostCloseDrain(messagesBeforeClose: Int) async {
        let startedAt = DispatchTime.now()
        let minWaitMs = 120.0
        let maxWaitMs = 900.0
        let noMessageGraceMs = 350.0
        let idleAfterMessageMs = 240.0

        while true {
            let waitedMs = elapsedMs(since: startedAt)
            if waitedMs >= maxWaitMs {
                return
            }
            if waitedMs < minWaitMs {
                try? await Task.sleep(nanoseconds: 40_000_000)
                continue
            }

            if messageCount > messagesBeforeClose {
                let idleMs = elapsedMs(since: lastMessageAt)
                if idleMs >= idleAfterMessageMs {
                    return
                }
            } else if waitedMs >= noMessageGraceMs {
                return
            }

            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    private func flushPendingChunks() async {
        guard !pendingChunks.isEmpty else {
            return
        }

        let buffered = pendingChunks
        pendingChunks.removeAll(keepingCapacity: false)
        for chunk in buffered {
            await sendChunk(chunk)
        }
    }

    private func sendChunk(_ chunk: Data) async {
        guard let task = webSocketTask else { return }
        do {
            try await task.send(.data(chunk))
            sentPCMBytes += chunk.count
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func estimateDurationSeconds() -> Double {
        guard sampleRate > 0, sentPCMBytes > 0 else {
            return 0
        }
        let samples = Double(sentPCMBytes) / Double(MemoryLayout<Int16>.size)
        return samples / Double(sampleRate)
    }

    private func elapsedMs(since start: DispatchTime, to end: DispatchTime = .now()) -> Double {
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else {
            return
        }

        while true {
            do {
                let message = try await task.receive()
                messageCount += 1
                lastMessageAt = .now()
                switch message {
                case .string(let text):
                    consume(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        consume(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                break
            }
        }
    }

    private func consume(_ text: String) {
        consumeControlEvent(text)

        guard let parsed = parseDeepgramMessageWithDuration(text) else {
            return
        }

        if parsed.duration > 0 {
            duration = parsed.duration
        }
        if let requestID = parsed.requestID {
            self.requestID = requestID
        }

        let transcript = parsed.chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return
        }

        if parsed.chunk.isFinal {
            finalSegments.append(transcript)
            partial = ""
            finalChunkCount += 1
        } else {
            partial = transcript
        }

        if parsed.isSpeechFinal {
            speechFinalCount += 1
        }
    }

    private func consumeControlEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            return
        }

        if type == "Metadata" {
            metadataEventCount += 1
            if let duration = object["duration"] as? Double, duration > 0 {
                self.duration = duration
            }
            if let requestID = object["request_id"] as? String, !requestID.isEmpty {
                self.requestID = requestID
            }
        }
    }

    private func msString(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
