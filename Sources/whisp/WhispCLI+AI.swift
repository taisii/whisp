import Foundation
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
        let language = languageParam(languageHint)

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

    static func analyzeVisionContextGemini(
        apiKey: String,
        imageData: Data,
        mimeType: String
    ) async throws -> ContextInfo? {
        let prompt = """
        スクリーンショットを解析し、音声整形用のコンテキストをJSONのみで返してください。
        形式: {"summary":"...","terms":["..."]}
        ルール:
        - summary は1文で簡潔
        - terms は専門用語・固有名詞を最大10個
        - 情報がなければ summary は空文字、terms は空配列
        - JSON以外は出力しない
        """

        let body = GeminiVisionRequest(contents: [
            GeminiVisionContent(
                role: "user",
                parts: [
                    .text(prompt),
                    .inline(mimeType: mimeType, data: imageData.base64EncodedString()),
                ]
            ),
        ])
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(LLMModel.gemini25FlashLite.modelName):generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
            throw AppError.invalidArgument("Gemini URL生成に失敗")
        }
        let data = try await sendJSONRequest(url: url, headers: [:], body: body)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = decoded.candidates.first?.content.joinedText ?? ""
        guard let vision = parseVisionContext(text) else {
            return nil
        }
        return ContextInfo(visionSummary: vision.summary, visionTerms: vision.terms)
    }

    static func loadConfig() throws -> Config {
        let configStore = try ConfigStore()
        return try configStore.loadOrCreate()
    }

    static func deepgramAPIKey(from config: Config) throws -> String {
        let key = config.apiKeys.deepgram.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AppError.invalidArgument("Deepgram APIキーが未設定です")
        }
        return key
    }

    static func llmAPIKey(config: Config, model: LLMModel) throws -> String {
        switch model {
        case .gemini25FlashLite, .gemini25FlashLiteAudio:
            let key = config.apiKeys.gemini.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw AppError.invalidArgument("Gemini APIキーが未設定です")
            }
            return key
        case .gpt4oMini, .gpt5Nano:
            let key = config.apiKeys.openai.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw AppError.invalidArgument("OpenAI APIキーが未設定です")
            }
            return key
        }
    }

    static func effectivePostProcessModel(_ model: LLMModel) -> LLMModel {
        switch model {
        case .gemini25FlashLiteAudio:
            return .gemini25FlashLite
        default:
            return model
        }
    }

    static func resolveIntentJudgeContext(
        config: Config,
        preferredModel: LLMModel?
    ) throws -> (model: LLMModel, apiKey: String) {
        if let preferredModel {
            let model = effectivePostProcessModel(preferredModel)
            return (model, try llmAPIKey(config: config, model: model))
        }

        let openAIKey = config.apiKeys.openai.trimmingCharacters(in: .whitespacesAndNewlines)
        if !openAIKey.isEmpty {
            return (.gpt5Nano, openAIKey)
        }

        let geminiKey = config.apiKeys.gemini.trimmingCharacters(in: .whitespacesAndNewlines)
        if !geminiKey.isEmpty {
            return (.gemini25FlashLite, geminiKey)
        }

        throw AppError.invalidArgument("intent judge 用のAPIキーが未設定です（openai または gemini）")
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
                LLMUsage(model: LLMModel.gemini25FlashLite.modelName, promptTokens: $0.promptTokenCount, completionTokens: $0.candidatesTokenCount)
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
                LLMUsage(model: model.modelName, promptTokens: $0.promptTokens, completionTokens: $0.completionTokens)
            }
            return PostProcessResult(text: text, usage: usage)
        }
    }
    static func sendJSONRequest<T: Encodable>(
        url: URL,
        headers: [String: String],
        body: T
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.io("HTTPレスポンスが不正")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AppError.io("API request failed (\(http.statusCode)): \(bodyText)")
        }
        return data
    }
}
