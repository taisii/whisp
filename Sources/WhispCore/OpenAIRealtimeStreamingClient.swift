import Foundation

private func realtimeElapsedMs(since start: DispatchTime) -> Double {
    let now = DispatchTime.now()
    let nanos = now.uptimeNanoseconds >= start.uptimeNanoseconds
        ? now.uptimeNanoseconds - start.uptimeNanoseconds
        : 0
    return Double(nanos) / 1_000_000.0
}

private struct OpenAIRealtimeEvent: Decodable {
    let type: String
    let delta: String?
    let transcript: String?
    let text: String?
    let item: OpenAIRealtimeItem?
    let response: OpenAIRealtimeResponse?
    let error: OpenAIRealtimeError?
}

private struct OpenAIRealtimeItem: Decodable {
    let type: String?
    let delta: String?
    let transcript: String?
    let text: String?
    let content: [OpenAIRealtimeContent]?
}

private struct OpenAIRealtimeResponse: Decodable {
    let transcript: String?
    let outputText: String?
    let output: [OpenAIRealtimeOutput]?

    enum CodingKeys: String, CodingKey {
        case transcript
        case outputText = "output_text"
        case output
    }
}

private struct OpenAIRealtimeOutput: Decodable {
    let transcript: String?
    let text: String?
    let content: [OpenAIRealtimeContent]?
}

private struct OpenAIRealtimeContent: Decodable {
    let type: String?
    let transcript: String?
    let text: String?
}

private struct OpenAIRealtimeError: Decodable {
    let message: String?
}

private struct OpenAISessionUpdateEvent: Encodable {
    let type = "session.update"
    let session: OpenAISessionConfig
}

private struct OpenAISessionConfig: Encodable {
    let inputAudioFormat: String
    let inputAudioTranscription: OpenAIInputAudioTranscription
    let turnDetection: OpenAITurnDetection

    enum CodingKeys: String, CodingKey {
        case inputAudioFormat = "input_audio_format"
        case inputAudioTranscription = "input_audio_transcription"
        case turnDetection = "turn_detection"
    }
}

private struct OpenAIInputAudioTranscription: Encodable {
    let model: String
}

private struct OpenAITurnDetection: Encodable {
    let type: String
}

private struct OpenAIInputAudioAppendEvent: Encodable {
    let type = "input_audio_buffer.append"
    let audio: String
}

private struct OpenAIInputAudioCommitEvent: Encodable {
    let type = "input_audio_buffer.commit"
}

private struct OpenAIResponseCreateEvent: Encodable {
    let type = "response.create"
}

public actor OpenAIRealtimeStreamingClient {
    private let session: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var started = false
    private var ready = false
    private var pendingChunks: [Data] = []

    private var partialSegments: [String] = []
    private var finalSegments: [String] = []
    private var messageCount = 0
    private var lastMessageAt: DispatchTime = .now()
    private var sendError: String?
    private var finalizationError: String?
    private var sentPCMBytes: Int = 0
    private var sampleRate: Int = 16_000

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private func errorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
    }

    public func start(
        apiKey: String,
        sampleRate: Int,
        language: String?,
        sessionModel: String = "gpt-4o-mini-realtime-preview",
        transcriptionModel: String = "gpt-4o-mini-transcribe"
    ) async throws {
        guard !started else {
            return
        }

        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")
        components?.queryItems = [URLQueryItem(name: "model", value: sessionModel)]
        guard let url = components?.url else {
            throw AppError.invalidArgument("OpenAI Realtime URL生成に失敗")
        }

        var request = URLRequest(url: url)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let task = session.webSocketTask(with: request)
        task.resume()

        webSocketTask = task
        started = true
        ready = false
        // Keep chunks submitted before `start` was reached; they are flushed after handshake.
        partialSegments.removeAll(keepingCapacity: false)
        finalSegments.removeAll(keepingCapacity: false)
        messageCount = 0
        lastMessageAt = .now()
        sendError = nil
        finalizationError = nil
        sentPCMBytes = 0
        self.sampleRate = max(1, sampleRate)

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        // URLSessionWebSocketTask は resume 直後だと send が失敗することがあるため、
        // ごく短時間だけ待ってから初期イベントを送る。
        try? await Task.sleep(nanoseconds: 400_000_000)

        let sessionUpdate = OpenAISessionUpdateEvent(
            session: OpenAISessionConfig(
                inputAudioFormat: "pcm16",
                inputAudioTranscription: OpenAIInputAudioTranscription(model: transcriptionModel),
                turnDetection: OpenAITurnDetection(type: "server_vad")
            )
        )

        do {
            try await send(event: sessionUpdate)
            if let language {
                // 現時点で language 指定は必須ではないため、互換性優先で接続後ログ用途のみ保持する。
                _ = language
            }
        } catch {
            started = false
            ready = false
            finalizationError = errorDescription(error)
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            throw AppError.io("OpenAI Realtime start failed: \(errorDescription(error))")
        }

        try? await Task.sleep(nanoseconds: 120_000_000)
        ready = true
        await flushPendingChunks()
    }

    public func start(
        apiKey: String,
        sampleRate: Int,
        language: String?,
        model: String
    ) async throws {
        try await start(
            apiKey: apiKey,
            sampleRate: sampleRate,
            language: language,
            sessionModel: "gpt-4o-mini-realtime-preview",
            transcriptionModel: model
        )
    }

    public func enqueueAudioChunk(_ chunk: Data) async {
        guard !chunk.isEmpty else { return }

        if !started || !ready {
            pendingChunks.append(chunk)
            return
        }

        await sendChunk(chunk)
    }

    public func finish() async throws -> (transcript: String, usage: STTUsage?) {
        guard started else {
            throw AppError.io("OpenAI Realtime streaming is not started")
        }

        await flushPendingChunks()

        do {
            try await send(event: OpenAIInputAudioCommitEvent())
        } catch {
            finalizationError = errorDescription(error)
        }

        await waitForFinalizationDrain()

        let currentReceiveTask = receiveTask
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        if let currentReceiveTask {
            _ = await currentReceiveTask.result
        }

        started = false
        ready = false
        webSocketTask = nil
        receiveTask = nil

        let transcript = resolveTranscript()
        if transcript.isEmpty {
            if let finalizationError {
                throw AppError.io("OpenAI Realtime finalize failed: \(finalizationError)")
            }
            if let sendError {
                throw AppError.io("OpenAI Realtime send failed: \(sendError)")
            }
            throw AppError.io("OpenAI Realtime transcript が空です")
        }

        let bytesPerSecond = max(1, sampleRate * MemoryLayout<Int16>.size)
        let usageDuration = sentPCMBytes > 0 ? Double(sentPCMBytes) / Double(bytesPerSecond) : 0
        let usage = usageDuration > 0
            ? STTUsage(durationSeconds: usageDuration, requestID: nil, provider: STTProvider.whisper.rawValue)
            : nil
        return (transcript, usage)
    }

    private func waitForFinalizationDrain() async {
        let startedAt = DispatchTime.now()
        let maxWaitMs = 5_000.0
        let minWaitMs = 250.0
        let idleThresholdMs = 320.0

        while true {
            let elapsed = realtimeElapsedMs(since: startedAt)
            if elapsed >= maxWaitMs {
                return
            }
            if elapsed < minWaitMs {
                try? await Task.sleep(nanoseconds: 40_000_000)
                continue
            }

            let hasFinal = !finalSegments.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let idleMs = realtimeElapsedMs(since: lastMessageAt)
            if hasFinal && idleMs >= idleThresholdMs {
                return
            }
            if messageCount == 0 && elapsed >= 1_200 {
                return
            }

            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    private func sendChunk(_ chunk: Data) async {
        sentPCMBytes += chunk.count
        let event = OpenAIInputAudioAppendEvent(audio: chunk.base64EncodedString())
        do {
            try await send(event: event)
        } catch {
            sendError = errorDescription(error)
        }
    }

    private func flushPendingChunks() async {
        guard !pendingChunks.isEmpty else { return }
        let chunks = pendingChunks
        pendingChunks.removeAll(keepingCapacity: false)
        for chunk in chunks {
            await sendChunk(chunk)
        }
    }

    private func send<T: Encodable>(event: T) async throws {
        guard let webSocketTask else {
            throw AppError.io("OpenAI Realtime socket が未接続です")
        }
        let data = try JSONEncoder().encode(event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppError.io("OpenAI Realtime event エンコードに失敗")
        }
        try await webSocketTask.send(.string(text))
    }

    private func receiveLoop() async {
        while let webSocketTask {
            do {
                let message = try await webSocketTask.receive()
                switch message {
                case let .string(text):
                    await handleMessage(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleMessage(text)
                    }
                @unknown default:
                    continue
                }
            } catch {
                if finalizationError == nil {
                    finalizationError = errorDescription(error)
                }
                break
            }
        }
    }

    private func handleMessage(_ raw: String) async {
        messageCount += 1
        lastMessageAt = .now()

        guard let data = raw.data(using: .utf8),
              let event = try? JSONDecoder().decode(OpenAIRealtimeEvent.self, from: data)
        else {
            return
        }

        if let err = event.error?.message, !err.isEmpty {
            finalizationError = err
        }

        let fragments = Self.extractTranscriptFragments(event: event)
        for fragment in fragments {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if Self.isFinalEventType(event.type) {
                finalSegments.append(trimmed)
            } else {
                partialSegments.append(trimmed)
            }
        }
    }

    private func resolveTranscript() -> String {
        let finals = finalSegments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !finals.isEmpty {
            return finals
        }
        let partial = partialSegments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return partial
    }

    private static func extractTranscriptFragments(event: OpenAIRealtimeEvent) -> [String] {
        var texts: [String] = []

        if let delta = event.delta, !delta.isEmpty {
            texts.append(delta)
        }
        if let transcript = event.transcript, !transcript.isEmpty {
            texts.append(transcript)
        }
        if let text = event.text, !text.isEmpty {
            texts.append(text)
        }

        if let item = event.item {
            if let delta = item.delta, !delta.isEmpty { texts.append(delta) }
            if let transcript = item.transcript, !transcript.isEmpty { texts.append(transcript) }
            if let text = item.text, !text.isEmpty { texts.append(text) }
            if let content = item.content {
                for c in content {
                    if let transcript = c.transcript, !transcript.isEmpty { texts.append(transcript) }
                    if let text = c.text, !text.isEmpty { texts.append(text) }
                }
            }
        }

        if let response = event.response {
            if let transcript = response.transcript, !transcript.isEmpty { texts.append(transcript) }
            if let outputText = response.outputText, !outputText.isEmpty { texts.append(outputText) }
            if let output = response.output {
                for out in output {
                    if let transcript = out.transcript, !transcript.isEmpty { texts.append(transcript) }
                    if let text = out.text, !text.isEmpty { texts.append(text) }
                    if let content = out.content {
                        for c in content {
                            if let transcript = c.transcript, !transcript.isEmpty { texts.append(transcript) }
                            if let text = c.text, !text.isEmpty { texts.append(text) }
                        }
                    }
                }
            }
        }

        return texts
    }

    private static func isFinalEventType(_ type: String) -> Bool {
        type.contains("completed") ||
            type.contains("done") ||
            type == "response.output_text.done" ||
            type == "conversation.item.input_audio_transcription.completed"
    }
}
