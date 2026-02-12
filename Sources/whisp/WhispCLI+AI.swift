import Foundation
import ImageIO
#if canImport(Speech)
import Speech
#endif
import Vision
import WhispCore

extension WhispCLI {
    static func runSTTInference(
        provider: STTProvider,
        apiKey: String,
        audio: AudioData,
        languageHint: String,
        mode: STTMode,
        chunkMs: Int,
        realtime: Bool
    ) async throws -> (
        transcript: String,
        totalMs: Double,
        afterStopMs: Double,
        replayStartedAtMs: Int64?,
        replayEndedAtMs: Int64?,
        attempts: [BenchmarkSTTAttempt]
    ) {
        let sampleRate = Int(audio.sampleRate)
        let language = LanguageResolver.languageParam(languageHint)

        switch provider {
        case .deepgram:
            switch mode {
            case .rest:
                let replayStartedAtMs: Int64?
                let replayEndedAtMs: Int64?
                if realtime {
                    replayStartedAtMs = nowEpochMs()
                    let durationNs = audioReplayDurationNanoseconds(audio: audio, sampleRate: sampleRate)
                    if durationNs > 0 {
                        try? await Task.sleep(nanoseconds: durationNs)
                    }
                    replayEndedAtMs = nowEpochMs()
                } else {
                    replayStartedAtMs = nil
                    replayEndedAtMs = nil
                }
                let attemptStartedAtMs = nowEpochMs()
                let startedAt = DispatchTime.now()
                let result = try await DeepgramClient().transcribe(
                    apiKey: apiKey,
                    sampleRate: sampleRate,
                    audio: audio.pcmBytes,
                    language: language
                )
                let total = elapsedMs(since: startedAt)
                let attemptEndedAtMs = nowEpochMs()
                return (
                    result.transcript,
                    total,
                    total,
                    replayStartedAtMs,
                    replayEndedAtMs,
                    [BenchmarkSTTAttempt(
                        kind: "rest",
                        status: .ok,
                        startedAtMs: attemptStartedAtMs,
                        endedAtMs: attemptEndedAtMs
                    )]
                )
            case .stream:
                let stream = DeepgramStreamingClient()
                let chunkSamples = max(1, sampleRate * chunkMs / 1000)
                let chunkBytes = chunkSamples * MemoryLayout<Int16>.size

                try await stream.start(apiKey: apiKey, sampleRate: sampleRate, language: language)
                let replayStartedAtMs = nowEpochMs()
                let sendAttemptStartedAtMs = replayStartedAtMs
                let sendStartedAt = DispatchTime.now()
                var offset = 0
                while offset < audio.pcmBytes.count {
                    let end = min(offset + chunkBytes, audio.pcmBytes.count)
                    await stream.enqueueAudioChunk(audio.pcmBytes.subdata(in: offset..<end))
                    if realtime {
                        let frameCount = (end - offset) / MemoryLayout<Int16>.size
                        let seconds = Double(frameCount) / Double(sampleRate)
                        let nanoseconds = UInt64(seconds * 1_000_000_000)
                        if nanoseconds > 0 {
                            try? await Task.sleep(nanoseconds: nanoseconds)
                        }
                    }
                    offset = end
                }
                let sendMs = elapsedMs(since: sendStartedAt)
                let replayEndedAtMs = nowEpochMs()
                let sendAttemptEndedAtMs = replayEndedAtMs
                let finalizeStartedAt = DispatchTime.now()
                let finalizeAttemptStartedAtMs = nowEpochMs()
                let result = try await stream.finish()
                let finalizeMs = elapsedMs(since: finalizeStartedAt)
                let finalizeAttemptEndedAtMs = nowEpochMs()
                return (
                    result.transcript,
                    sendMs + finalizeMs,
                    finalizeMs,
                    replayStartedAtMs,
                    replayEndedAtMs,
                    [
                        BenchmarkSTTAttempt(
                            kind: "stream_send",
                            status: .ok,
                            startedAtMs: sendAttemptStartedAtMs,
                            endedAtMs: sendAttemptEndedAtMs
                        ),
                        BenchmarkSTTAttempt(
                            kind: "stream_finalize",
                            status: .ok,
                            startedAtMs: finalizeAttemptStartedAtMs,
                            endedAtMs: finalizeAttemptEndedAtMs
                        ),
                    ]
                )
            }
        case .whisper:
            guard mode == .rest else {
                throw AppError.invalidArgument("whisper は --stt rest のみ対応です")
            }
            let replayStartedAtMs: Int64?
            let replayEndedAtMs: Int64?
            if realtime {
                replayStartedAtMs = nowEpochMs()
                let durationNs = audioReplayDurationNanoseconds(audio: audio, sampleRate: sampleRate)
                if durationNs > 0 {
                    try? await Task.sleep(nanoseconds: durationNs)
                }
                replayEndedAtMs = nowEpochMs()
            } else {
                replayStartedAtMs = nil
                replayEndedAtMs = nil
            }
            let attemptStartedAtMs = nowEpochMs()
            let startedAt = DispatchTime.now()
            let result = try await WhisperClient().transcribe(
                apiKey: apiKey,
                sampleRate: sampleRate,
                audio: audio.pcmBytes,
                language: language
            )
            let total = elapsedMs(since: startedAt)
            let attemptEndedAtMs = nowEpochMs()
            return (
                result.transcript,
                total,
                total,
                replayStartedAtMs,
                replayEndedAtMs,
                [BenchmarkSTTAttempt(
                    kind: "rest",
                    status: .ok,
                    startedAtMs: attemptStartedAtMs,
                    endedAtMs: attemptEndedAtMs
                )]
            )
        case .appleSpeech:
            guard mode == .rest else {
                throw AppError.invalidArgument("apple_speech は --stt rest のみ対応です")
            }
            let replayStartedAtMs: Int64?
            let replayEndedAtMs: Int64?
            if realtime {
                replayStartedAtMs = nowEpochMs()
                let durationNs = audioReplayDurationNanoseconds(audio: audio, sampleRate: sampleRate)
                if durationNs > 0 {
                    try? await Task.sleep(nanoseconds: durationNs)
                }
                replayEndedAtMs = nowEpochMs()
            } else {
                replayStartedAtMs = nil
                replayEndedAtMs = nil
            }
            let attemptStartedAtMs = nowEpochMs()
            let startedAt = DispatchTime.now()
            let transcript = try await transcribeWithAppleSpeech(
                sampleRate: sampleRate,
                audio: audio.pcmBytes,
                language: language
            )
            let total = elapsedMs(since: startedAt)
            let attemptEndedAtMs = nowEpochMs()
            return (
                transcript,
                total,
                total,
                replayStartedAtMs,
                replayEndedAtMs,
                [BenchmarkSTTAttempt(
                    kind: "rest",
                    status: .ok,
                    startedAtMs: attemptStartedAtMs,
                    endedAtMs: attemptEndedAtMs
                )]
            )
        }
    }

    private static func audioReplayDurationNanoseconds(audio: AudioData, sampleRate: Int) -> UInt64 {
        guard sampleRate > 0 else { return 0 }
        let frameCount = audio.pcmBytes.count / MemoryLayout<Int16>.size
        let seconds = Double(frameCount) / Double(sampleRate)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000)
    }

    static func analyzeVisionContextOCR(imageData: Data) throws -> ContextInfo? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ja-JP", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        let lines = normalizeOCRLines(observations)
        guard !lines.isEmpty else {
            return nil
        }

        let windowText = lines.joined(separator: "\n")
        let summary = String(lines.prefix(2).joined(separator: " / ").prefix(180))
        let terms = extractCandidateTerms(from: lines, limit: 10)
        return ContextInfo(
            windowText: tailExcerpt(from: windowText, maxChars: 1200),
            visionSummary: summary.isEmpty ? nil : summary,
            visionTerms: terms
        )
    }

    static func loadConfig() throws -> Config {
        let configStore = try ConfigStore()
        try configStore.ensureExists(default: Config())
        return try configStore.load()
    }

    static func runIntentJudge(
        model: LLMModel,
        apiKey: String,
        reference: IntentLabel,
        hypothesisText: String
    ) async throws -> IntentJudgeResult {
        let prompt = """
        あなたは音声UIの評価者です。reference intent と hypothesis text を比較して、意図一致を判定してください。
        出力はJSONのみで、余計な説明文は禁止です。

        schema:
        {"match":boolean,"score":0-4,"error_type":"none|intent_mismatch|slot_mismatch|missing_info|extra_info","reason":"短い理由"}

        reference_intent_json:
        \(reference.canonicalJSONString)

        hypothesis_text:
        \(hypothesisText)
        """

        let responseText: String
        switch model {
        case .gemini25FlashLite, .gemini25FlashLiteAudio:
            let body = GeminiTextRequest(contents: [
                GeminiTextContent(role: "user", parts: [GeminiTextPart(text: prompt)]),
            ])
            let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(LLMModel.gemini25FlashLite.modelName):generateContent?key=\(apiKey)"
            guard let url = URL(string: endpoint) else {
                throw AppError.invalidArgument("Gemini URL生成に失敗")
            }
            let data = try await sendJSONRequest(url: url, headers: [:], body: body)
            let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
            responseText = decoded.candidates.first?.content.joinedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .gpt4oMini, .gpt5Nano:
            let body = OpenAITextRequest(model: model.modelName, messages: [OpenAITextMessage(role: "user", content: prompt)])
            guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
                throw AppError.invalidArgument("OpenAI URL生成に失敗")
            }
            let headers = ["Authorization": "Bearer \(apiKey)"]
            let data = try await sendJSONRequest(url: url, headers: headers, body: body)
            let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            responseText = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let jsonText = extractedJSONObjectText(from: responseText)
        guard let data = jsonText.data(using: .utf8) else {
            throw AppError.decode("intent judge response parse failed")
        }
        let decoded = try JSONDecoder().decode(IntentJudgeResponse.self, from: data)
        let score = max(0, min(4, decoded.score))
        return IntentJudgeResult(match: decoded.match, score: score)
    }

    static func runLLMEvaluation(
        model: LLMModel,
        apiKey: String,
        referenceText: String,
        hypothesisText: String,
        context: ContextInfo?
    ) async throws -> LLMEvaluationResult {
        let contextSnippet = llmEvalContextSnippet(context: context)
        let prompt = """
        あなたは音声入力ベンチマークの審査員です。reference と hypothesis を比較し、JSONのみで出力してください。

        出力スキーマ:
        {"intent_preservation_score":0.0-1.0,"hallucination_score":0.0-1.0,"hallucination_rate":0.0-1.0,"error_type":"none|intent_drop|hallucination|both","reason":"短い理由"}

        判定基準:
        - intent_preservation_score: referenceの依頼意図がどれだけ保持されたか
        - hallucination_score: 根拠のない追加情報が少ないほど高得点
        - hallucination_rate: hallucination_score と逆方向（高いほど幻覚が多い）

        reference_text:
        \(referenceText)

        hypothesis_text:
        \(hypothesisText)

        context_excerpt:
        \(contextSnippet)
        """

        let responseText: String
        switch model {
        case .gemini25FlashLite, .gemini25FlashLiteAudio:
            let body = GeminiTextRequest(contents: [
                GeminiTextContent(role: "user", parts: [GeminiTextPart(text: prompt)]),
            ])
            let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(LLMModel.gemini25FlashLite.modelName):generateContent?key=\(apiKey)"
            guard let url = URL(string: endpoint) else {
                throw AppError.invalidArgument("Gemini URL生成に失敗")
            }
            let data = try await sendJSONRequest(url: url, headers: [:], body: body)
            let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
            responseText = decoded.candidates.first?.content.joinedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .gpt4oMini, .gpt5Nano:
            let body = OpenAITextRequest(model: model.modelName, messages: [OpenAITextMessage(role: "user", content: prompt)])
            guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
                throw AppError.invalidArgument("OpenAI URL生成に失敗")
            }
            let headers = ["Authorization": "Bearer \(apiKey)"]
            let data = try await sendJSONRequest(url: url, headers: headers, body: body)
            let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            responseText = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let jsonText = extractedJSONObjectText(from: responseText)
        guard let data = jsonText.data(using: .utf8) else {
            throw AppError.decode("llm eval response parse failed")
        }
        let decoded = try JSONDecoder().decode(LLMEvaluationResponse.self, from: data)
        return LLMEvaluationResult(
            intentPreservationScore: clampedScore(decoded.intentPreservationScore),
            hallucinationScore: clampedScore(decoded.hallucinationScore),
            hallucinationRate: clampedScore(decoded.hallucinationRate)
        )
    }

    static func extractedJSONObjectText(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start < end
        {
            return String(trimmed[start...end])
        }
        return trimmed
    }

    static func postProcessText(
        model: LLMModel,
        apiKey: String,
        config: Config,
        sttText: String,
        context: ContextInfo?,
        sttMode: String
    ) async throws -> PostProcessResult {
        let sanitizedContext = sanitizeContextForPrompt(context)
        let prompt = buildPrompt(
            sttResult: sttText,
            languageHint: config.inputLanguage,
            appName: nil,
            appPromptRules: config.appPromptRules,
            context: sanitizedContext
        )
        PromptTrace.dump(
            stage: "pipeline_benchmark_postprocess",
            model: model.rawValue,
            appName: nil,
            context: sanitizedContext,
            prompt: prompt,
            extra: [
                "stt_mode": sttMode,
                "stt_chars": String(sttText.count),
                "language_hint": config.inputLanguage,
            ]
        )

        switch model {
        case .gemini25FlashLite, .gemini25FlashLiteAudio:
            let body = GeminiTextRequest(contents: [
                GeminiTextContent(role: "user", parts: [GeminiTextPart(text: prompt)]),
            ])
            let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(LLMModel.gemini25FlashLite.modelName):generateContent?key=\(apiKey)"
            guard let url = URL(string: endpoint) else {
                throw AppError.invalidArgument("Gemini URL生成に失敗")
            }
            let data = try await sendJSONRequest(url: url, headers: [:], body: body)
            let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
            let text = decoded.candidates.first?.content.joinedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let usage = decoded.usageMetadata.map {
                LLMUsage(
                    model: LLMModel.gemini25FlashLite.modelName,
                    promptTokens: $0.promptTokenCount,
                    completionTokens: $0.candidatesTokenCount,
                    provider: "gemini"
                )
            }
            return PostProcessResult(text: text, usage: usage)
        case .gpt4oMini, .gpt5Nano:
            let body = OpenAITextRequest(model: model.modelName, messages: [OpenAITextMessage(role: "user", content: prompt)])
            guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
                throw AppError.invalidArgument("OpenAI URL生成に失敗")
            }
            let headers = ["Authorization": "Bearer \(apiKey)"]
            let data = try await sendJSONRequest(url: url, headers: headers, body: body)
            let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            let text = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let usage = decoded.usage.map {
                LLMUsage(model: model.modelName, promptTokens: $0.promptTokens, completionTokens: $0.completionTokens, provider: "openai")
            }
            return PostProcessResult(text: text, usage: usage)
        }
    }
    static func sendJSONRequest<T: Encodable>(
        url: URL,
        headers: [String: String],
        body: T
    ) async throws -> Data {
        try await HTTPJSONClient().sendJSONRequest(
            url: url,
            method: "POST",
            headers: headers,
            body: body
        )
    }

    private static func normalizeOCRLines(_ observations: [VNRecognizedTextObservation]) -> [String] {
        var seen: Set<String> = []
        var lines: [String] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                lines.append(String(normalized.prefix(180)))
            }
            if lines.count >= 80 {
                break
            }
        }
        return lines
    }

    private static func extractCandidateTerms(from lines: [String], limit: Int) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var seen: Set<String> = []
        var terms: [String] = []
        for line in lines {
            for token in line.components(separatedBy: separators) {
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2, trimmed.count <= 40 else { continue }
                guard trimmed.rangeOfCharacter(from: .letters) != nil else { continue }
                if seen.insert(trimmed).inserted {
                    terms.append(trimmed)
                }
                if terms.count >= limit {
                    return terms
                }
            }
        }
        return terms
    }

    private static func sanitizeContextForPrompt(_ context: ContextInfo?) -> ContextInfo? {
        guard let context else {
            return nil
        }
        let sanitized = ContextInfo(
            accessibilityText: context.accessibilityText,
            visionSummary: context.visionSummary,
            visionTerms: context.visionTerms
        )
        return sanitized.isEmpty ? nil : sanitized
    }

    private static func tailExcerpt(from text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        let ns = text as NSString
        guard ns.length > 0 else { return "" }
        let length = min(ns.length, maxChars)
        let location = ns.length - length
        return ns.substring(with: NSRange(location: location, length: length))
    }

    private static func llmEvalContextSnippet(context: ContextInfo?) -> String {
        guard let context else {
            return "none"
        }
        var lines: [String] = []
        if let summary = context.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append("visionSummary: \(String(summary.prefix(300)))")
        }
        if !context.visionTerms.isEmpty {
            lines.append("visionTerms: \(context.visionTerms.prefix(12).joined(separator: ", "))")
        }
        if let accessibility = context.accessibilityText?.trimmingCharacters(in: .whitespacesAndNewlines), !accessibility.isEmpty {
            lines.append("accessibilityText: \(String(accessibility.prefix(300)))")
        }
        if let windowText = context.windowText?.trimmingCharacters(in: .whitespacesAndNewlines), !windowText.isEmpty {
            lines.append("windowText: \(String(windowText.prefix(300)))")
        }
        if lines.isEmpty {
            return "none"
        }
        return lines.joined(separator: "\n")
    }

    private static func transcribeWithAppleSpeech(
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> String {
#if canImport(Speech)
        let status = await resolveSpeechAuthorizationStatus()
        guard status == .authorized else {
            throw AppError.invalidArgument(speechAuthorizationErrorMessage(status))
        }

        let locale = localeForSpeechLanguage(language)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AppError.invalidArgument("Apple Speechが locale=\(locale.identifier) に対応していません")
        }
        guard recognizer.isAvailable else {
            throw AppError.io("Apple Speechが現在利用できません")
        }

        let normalizedSampleRate = max(sampleRate, 1)
        let wavData = buildWAVBytes(sampleRate: UInt32(normalizedSampleRate), pcmData: audio)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisp-apple-stt-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try wavData.write(to: tmpURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let request = SFSpeechURLRecognitionRequest(url: tmpURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true

        do {
            let transcript = try await recognizeSpeechTranscript(request: request, recognizer: recognizer)
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.io("Apple Speech 文字起こしに失敗: \(error.localizedDescription)")
        }
#else
        throw AppError.invalidArgument("この環境では Speech.framework が利用できません")
#endif
    }

#if canImport(Speech)
    private static func recognizeSpeechTranscript(
        request: SFSpeechURLRecognitionRequest,
        recognizer: SFSpeechRecognizer
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    guard !finished else { return }
                    finished = true
                    task?.cancel()
                    task = nil
                    continuation.resume(throwing: error)
                    return
                }

                guard let result, result.isFinal else {
                    return
                }
                guard !finished else { return }
                finished = true
                task = nil
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }

    private static func resolveSpeechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined {
            return current
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func speechAuthorizationErrorMessage(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return "音声認識権限が未許可です（システム設定 > プライバシーとセキュリティ > 音声認識）"
        case .restricted:
            return "このMacでは音声認識が制限されています"
        case .notDetermined:
            return "音声認識権限の確認中です。再度お試しください"
        case .authorized:
            return ""
        @unknown default:
            return "音声認識権限の状態を判定できませんでした"
        }
    }
#endif

    private static func localeForSpeechLanguage(_ language: String?) -> Locale {
        switch language {
        case "ja":
            return Locale(identifier: "ja-JP")
        case "en":
            return Locale(identifier: "en-US")
        case .some(let value):
            return Locale(identifier: value)
        case .none:
            return Locale.current
        }
    }

    private static func clampedScore(_ value: Double) -> Double {
        max(0, min(1, value))
    }
}
