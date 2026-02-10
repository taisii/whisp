import Foundation
import ImageIO
import Vision
import WhispCore

extension WhispCLI {
    static func runSTTInference(
        apiKey: String,
        audio: AudioData,
        languageHint: String,
        mode: STTMode,
        chunkMs: Int,
        realtime: Bool
    ) async throws -> (transcript: String, totalMs: Double, afterStopMs: Double) {
        let sampleRate = Int(audio.sampleRate)
        let language = LanguageResolver.languageParam(languageHint)

        switch mode {
        case .rest:
            let startedAt = DispatchTime.now()
            let result = try await DeepgramClient().transcribe(
                apiKey: apiKey,
                sampleRate: sampleRate,
                audio: audio.pcmBytes,
                language: language
            )
            let total = elapsedMs(since: startedAt)
            return (result.transcript, total, total)
        case .stream:
            let stream = DeepgramStreamingClient()
            let chunkSamples = max(1, sampleRate * chunkMs / 1000)
            let chunkBytes = chunkSamples * MemoryLayout<Int16>.size

            try await stream.start(apiKey: apiKey, sampleRate: sampleRate, language: language)
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
            let finalizeStartedAt = DispatchTime.now()
            let result = try await stream.finish()
            let finalizeMs = elapsedMs(since: finalizeStartedAt)
            return (result.transcript, sendMs + finalizeMs, finalizeMs)
        }
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
        let prompt = buildPrompt(
            sttResult: sttText,
            languageHint: config.inputLanguage,
            appName: nil,
            appPromptRules: config.appPromptRules,
            context: context
        )
        PromptTrace.dump(
            stage: "pipeline_benchmark_postprocess",
            model: model.rawValue,
            appName: nil,
            context: context,
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

    private static func tailExcerpt(from text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        let ns = text as NSString
        guard ns.length > 0 else { return "" }
        let length = min(ns.length, maxChars)
        let location = ns.length - length
        return ns.substring(with: NSRange(location: location, length: length))
    }
}
