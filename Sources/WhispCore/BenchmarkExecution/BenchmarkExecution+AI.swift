import Foundation
import ImageIO
#if canImport(Speech)
import AVFoundation
import Speech
#endif
import Vision

extension BenchmarkExecutor {
    static func runSTTInference(
        preset: STTPresetID,
        credential: STTCredential,
        audio: AudioData,
        languageHint: String,
        chunkMs: Int,
        realtime: Bool,
        segmentation: STTSegmentationConfig = STTSegmentationConfig()
    ) async throws -> (
        transcript: String,
        totalMs: Double,
        afterStopMs: Double,
        replayStartedAtMs: Int64?,
        replayEndedAtMs: Int64?,
        attempts: [BenchmarkSTTAttempt],
        segmentCount: Int?,
        vadSilenceCount: Int?
    ) {
        let sampleRate = Int(audio.sampleRate)
        let language = LanguageResolver.languageParam(languageHint)
        let presetSpec = STTPresetCatalog.spec(for: preset)
        let mode: STTMode = {
            switch presetSpec.mode {
            case .stream:
                return .stream
            case .rest:
                return .rest
            }
        }()

        switch presetSpec.engine {
        case .deepgram:
            let apiKey = try resolveAPIKey(credential, preset: preset)
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
                    )],
                    1,
                    0
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
                    ],
                    1,
                    0
                )
            }
        case .openAIWhisper:
            let apiKey = try resolveAPIKey(credential, preset: preset)
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
                    )],
                    1,
                    0
                )
            case .stream:
                let stream = OpenAIRealtimeStreamingClient()
                let chunkSamples = max(1, sampleRate * chunkMs / 1000)
                let chunkBytes = chunkSamples * MemoryLayout<Int16>.size

                try await stream.start(
                    apiKey: apiKey,
                    sampleRate: sampleRate,
                    language: language
                )
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
                    ],
                    1,
                    0
                )
            }
        case .appleSpeech:
            let appleModel = presetSpec.appleModel ?? .recognizer
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
                let transcript = try await transcribeWithAppleSpeech(
                    sampleRate: sampleRate,
                    audio: audio.pcmBytes,
                    language: language,
                    model: appleModel
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
                    )],
                    1,
                    0
                )
            case .stream:
#if canImport(Speech)
                switch appleModel {
                case .recognizer:
                    return try await runAppleSpeechSegmentedInference(
                        audio: audio,
                        sampleRate: sampleRate,
                        language: language,
                        chunkMs: chunkMs,
                        realtime: realtime,
                        segmentation: segmentation
                    )
                case .speechTranscriber, .dictationTranscriber:
                    return try await runAppleSpeechModernSegmentedInference(
                        model: appleModel,
                        audio: audio,
                        sampleRate: sampleRate,
                        language: language,
                        chunkMs: chunkMs,
                        realtime: realtime,
                        segmentation: segmentation
                    )
                }
#else
                throw AppError.invalidArgument("この環境では Speech.framework が利用できません")
#endif
            }
        }
    }

    private static func resolveAPIKey(_ credential: STTCredential, preset: STTPresetID) throws -> String {
        guard case let .apiKey(apiKey) = credential else {
            throw AppError.invalidArgument("preset=\(preset.rawValue) は APIキー認証が必要です")
        }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidArgument("preset=\(preset.rawValue) の APIキーが空です")
        }
        return trimmed
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

        let response = try await LLMGateway().postProcess(apiKey: apiKey, model: model, prompt: prompt)
        let responseText = response.text

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

        let response = try await LLMGateway().postProcess(apiKey: apiKey, model: model, prompt: prompt)
        let responseText = response.text

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

    static func runPairwiseJudge(
        model: LLMModel,
        apiKey: String,
        referenceText: String?,
        sttInputText: String,
        candidateAText: String,
        candidateBText: String,
        visionImageData: Data?,
        visionImageMimeType: String?
    ) async throws -> (result: PairwiseJudgeResult, prompt: String, responseJSON: String) {
        let prompt = buildPairwiseJudgePrompt(
            referenceText: referenceText,
            sttInputText: sttInputText,
            candidateAText: candidateAText,
            candidateBText: candidateBText
        )
        let mimeType = normalizedImageMimeType(visionImageMimeType)
        let hasImage = pairwiseJudgeHasImagePayload(
            visionImageData: visionImageData,
            normalizedMimeType: mimeType
        )

        let response: PostProcessResult
        if hasImage, let visionImageData, let mimeType {
            response = try await LLMGateway().judgeWithImage(
                apiKey: apiKey,
                model: model,
                prompt: prompt,
                imageData: visionImageData,
                imageMimeType: mimeType
            )
        } else {
            response = try await LLMGateway().postProcess(apiKey: apiKey, model: model, prompt: prompt)
        }
        let responseText = response.text

        let jsonText = extractedJSONObjectText(from: responseText)
        guard let data = jsonText.data(using: .utf8) else {
            throw AppError.decode("pairwise judge response parse failed")
        }
        let decoded = try JSONDecoder().decode(PairwiseJudgeResponse.self, from: data)
        let result = PairwiseJudgeResult(
            overallWinner: try parsePairwiseWinner(decoded.overallWinner),
            intentWinner: try parsePairwiseWinner(decoded.intentWinner),
            hallucinationWinner: try parsePairwiseWinner(decoded.hallucinationWinner),
            styleContextWinner: try parsePairwiseWinner(decoded.styleContextWinner),
            overallReason: decoded.overallReason?.trimmingCharacters(in: .whitespacesAndNewlines),
            intentReason: decoded.intentReason?.trimmingCharacters(in: .whitespacesAndNewlines),
            hallucinationReason: decoded.hallucinationReason?.trimmingCharacters(in: .whitespacesAndNewlines),
            styleContextReason: decoded.styleContextReason?.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: decoded.confidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return (result, prompt, jsonText)
    }

    static func buildPairwiseJudgePrompt(
        referenceText: String?,
        sttInputText: String,
        candidateAText: String,
        candidateBText: String
    ) -> String {
        let trimmedReference = (referenceText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let referenceBlock = trimmedReference.isEmpty ? "(none)" : trimmedReference
        let trimmedSTTInput = sttInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sttInputBlock = trimmedSTTInput.isEmpty ? "(none)" : trimmedSTTInput

        return """
        [role]
        あなたは音声入力ベンチマークの比較審査員です。候補A/Bを比較し、必ずJSONのみを返してください。

        [output_schema]
        {"overall_winner":"a|b|tie","intent_winner":"a|b|tie","hallucination_winner":"a|b|tie","style_context_winner":"a|b|tie","overall_reason":"短い理由","intent_reason":"短い理由","hallucination_reason":"短い理由","style_context_reason":"短い理由","confidence":"high|medium|low"}

        [evaluation_principles]
        - reference_text を主基準に、stt_input_text と添付画像（ある場合）を根拠として比較する。
        - STT入力は音声認識結果であり、誤認識を含む可能性がある前提で判断する。
        - intent_winner は、reference_text と添付画像（カーソル位置を含む）を手掛かりに、ユーザーが意図したであろう文を最も正しく再現できている候補を勝者とする。
        - hallucination_winner は、ユーザーが喋っていない内容を追加していない候補を勝者とする。stt_input_text / reference_text / 添付画像で裏付けできない情報、またはプレースホルダー由来の情報を付け加えた場合は減点する。
        - style_context_winner は、添付画像から推定できる敬語レベル・文体（丁寧/常体、業務/カジュアル等）により適合している候補を勝者とする。
        - overall_winner は上記3軸の多数決。多数がなければ tie。

        [reference_text]
        \(referenceBlock)

        [stt_input_text]
        \(sttInputBlock)

        [candidate_a_text]
        \(candidateAText)

        [candidate_b_text]
        \(candidateBText)
        """
    }

    static func pairwiseJudgeHasImagePayload(
        visionImageData: Data?,
        visionImageMimeType: String?
    ) -> Bool {
        pairwiseJudgeHasImagePayload(
            visionImageData: visionImageData,
            normalizedMimeType: normalizedImageMimeType(visionImageMimeType)
        )
    }

    static func normalizedImageMimeType(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.hasPrefix("image/") else {
            return nil
        }
        return trimmed
    }

    private static func pairwiseJudgeHasImagePayload(
        visionImageData: Data?,
        normalizedMimeType: String?
    ) -> Bool {
        (visionImageData?.isEmpty == false) && (normalizedMimeType?.isEmpty == false)
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

    static func makePostProcessPrompt(
        config: Config,
        sttText: String,
        context: ContextInfo?,
        templateOverride: String? = nil
    ) -> String {
        return buildPrompt(
            sttResult: sttText,
            languageHint: config.inputLanguage,
            appName: nil,
            appPromptRules: config.appPromptRules,
            context: context,
            templateOverride: templateOverride
        )
    }

    static func postProcessText(
        model: LLMModel,
        apiKey: String,
        config: Config,
        sttText: String,
        context: ContextInfo?,
        sttMode: String,
        templateOverride: String? = nil
    ) async throws -> PostProcessResult {
        let sanitizedContext = sanitizeContextForPrompt(context)
        let prompt = makePostProcessPrompt(
            config: config,
            sttText: sttText,
            context: sanitizedContext,
            templateOverride: templateOverride
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

        return try await LLMGateway().postProcess(apiKey: apiKey, model: model, prompt: prompt)
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
            windowText: context.windowText,
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

    private static func runAppleSpeechSegmentedInference(
        audio: AudioData,
        sampleRate: Int,
        language: String?,
        chunkMs: Int,
        realtime: Bool,
        segmentation: STTSegmentationConfig
    ) async throws -> (
        transcript: String,
        totalMs: Double,
        afterStopMs: Double,
        replayStartedAtMs: Int64?,
        replayEndedAtMs: Int64?,
        attempts: [BenchmarkSTTAttempt],
        segmentCount: Int?,
        vadSilenceCount: Int?
    ) {
#if canImport(Speech)
        let chunkSamples = max(1, sampleRate * chunkMs / 1_000)
        let chunkBytes = chunkSamples * MemoryLayout<Int16>.size
        let silenceMs = max(segmentation.silenceMs, 100)
        let maxSegmentMs = max(segmentation.maxSegmentMs, 1_000)
        let preRollMs = max(segmentation.preRollMs, 0)
        let preRollByteLimit = max(0, (sampleRate * preRollMs / 1_000) * MemoryLayout<Int16>.size)

        let replayStartedAtMs = nowEpochMs()
        var replayEndedAtMs = replayStartedAtMs
        var attempts: [BenchmarkSTTAttempt] = []
        var committedSegments: [STTCommittedSegment] = []
        var vadIntervals: [VADInterval] = []

        var stream: AppleSpeechStreamingRecognizer? = try await AppleSpeechStreamingRecognizer(sampleRate: sampleRate, language: language)
        var preRollBuffer = Data()
        var pendingPreRoll = Data()
        var segmentStartMs: Int64 = 0
        var segmentDurationMs = 0
        var silenceAccumulatedMs = 0
        var segmentHasSpeech = false
        var timelineMs: Int64 = 0
        var activeVADKind: String?
        var activeVADStartMs: Int64 = 0

        func appendPreRoll(_ chunk: Data) {
            guard preRollByteLimit > 0 else {
                return
            }
            preRollBuffer.append(chunk)
            if preRollBuffer.count > preRollByteLimit {
                preRollBuffer = Data(preRollBuffer.suffix(preRollByteLimit))
            }
        }

        func updateVAD(kind: String, startMs: Int64) {
            if activeVADKind == kind {
                return
            }
            if let activeVADKind {
                let interval = VADInterval(startMs: activeVADStartMs, endMs: startMs, kind: activeVADKind)
                if interval.endMs > interval.startMs {
                    vadIntervals.append(interval)
                }
            }
            activeVADKind = kind
            activeVADStartMs = startMs
        }

        func closeVAD(endMs: Int64) {
            guard let currentKind = activeVADKind else {
                return
            }
            let interval = VADInterval(startMs: activeVADStartMs, endMs: endMs, kind: currentKind)
            if interval.endMs > interval.startMs {
                vadIntervals.append(interval)
            }
            activeVADKind = nil
        }

        func ensureSegmentStreamStarted() async throws {
            if stream == nil {
                stream = try await AppleSpeechStreamingRecognizer(sampleRate: sampleRate, language: language)
                let rewind = Int64(min(preRollMs, Int(timelineMs)))
                segmentStartMs = max(0, timelineMs - rewind)
                segmentDurationMs = 0
                silenceAccumulatedMs = 0
                segmentHasSpeech = false
                if !pendingPreRoll.isEmpty {
                    await stream?.enqueue(pendingPreRoll)
                    pendingPreRoll.removeAll(keepingCapacity: false)
                }
            }
        }

        func commitSegment(reason: String, endMs: Int64) async throws {
            guard let currentStream = stream else {
                return
            }
            let commitStartedAtMs = nowEpochMs()
            let transcript = try await currentStream.finish()
            let commitEndedAtMs = nowEpochMs()
            attempts.append(BenchmarkSTTAttempt(
                kind: "segment_commit",
                status: .ok,
                startedAtMs: commitStartedAtMs,
                endedAtMs: commitEndedAtMs
            ))
            stream = nil
            pendingPreRoll = preRollBuffer
            segmentDurationMs = 0
            silenceAccumulatedMs = 0
            segmentHasSpeech = false
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                committedSegments.append(STTCommittedSegment(
                    index: committedSegments.count,
                    startMs: segmentStartMs,
                    endMs: max(segmentStartMs, endMs),
                    text: trimmed,
                    reason: reason
                ))
            }
        }

        var offset = 0
        while offset < audio.pcmBytes.count {
            let end = min(offset + chunkBytes, audio.pcmBytes.count)
            let chunk = audio.pcmBytes.subdata(in: offset..<end)
            let chunkDurationMs = max(1, chunkDurationMs(byteCount: chunk.count, sampleRate: sampleRate))
            let chunkStartMs = timelineMs
            timelineMs += Int64(chunkDurationMs)

            appendPreRoll(chunk)
            try await ensureSegmentStreamStarted()
            await stream?.enqueue(chunk)
            segmentDurationMs += chunkDurationMs

            let speech = isSpeechChunk(chunk)
            updateVAD(kind: speech ? "speech" : "silence", startMs: chunkStartMs)
            if speech {
                segmentHasSpeech = true
                silenceAccumulatedMs = 0
            } else {
                silenceAccumulatedMs += chunkDurationMs
            }

            if !speech, segmentHasSpeech, silenceAccumulatedMs >= silenceMs {
                try await commitSegment(reason: "silence", endMs: timelineMs)
            } else if segmentDurationMs >= maxSegmentMs {
                try await commitSegment(reason: "max_segment", endMs: timelineMs)
            }

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
        replayEndedAtMs = nowEpochMs()
        attempts.insert(BenchmarkSTTAttempt(
            kind: "stream_send",
            status: .ok,
            startedAtMs: replayStartedAtMs,
            endedAtMs: replayEndedAtMs
        ), at: 0)

        let finalizeStartedAt = DispatchTime.now()
        let finalizeAttemptStartedAtMs = nowEpochMs()
        try await commitSegment(reason: "stop", endMs: timelineMs)
        let finalizeMs = elapsedMs(since: finalizeStartedAt)
        let finalizeAttemptEndedAtMs = nowEpochMs()
        attempts.append(BenchmarkSTTAttempt(
            kind: "stream_finalize",
            status: .ok,
            startedAtMs: finalizeAttemptStartedAtMs,
            endedAtMs: finalizeAttemptEndedAtMs
        ))

        closeVAD(endMs: timelineMs)
        let transcript = committedSegments.map(\.text).joined(separator: "\n")
        let vadSilenceCount = vadIntervals.filter { $0.kind == "silence" }.count
        return (
            transcript,
            Double(max(0, finalizeAttemptEndedAtMs - replayStartedAtMs)),
            finalizeMs,
            replayStartedAtMs,
            replayEndedAtMs,
            attempts,
            committedSegments.count,
            vadSilenceCount
        )
#else
        throw AppError.invalidArgument("この環境では Speech.framework が利用できません")
#endif
    }

    private static func chunkDurationMs(byteCount: Int, sampleRate: Int) -> Int {
        guard byteCount > 0, sampleRate > 0 else {
            return 0
        }
        let sampleCount = byteCount / MemoryLayout<Int16>.size
        guard sampleCount > 0 else {
            return 0
        }
        return Int((Double(sampleCount) / Double(sampleRate)) * 1_000)
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

    private static func runAppleSpeechModernSegmentedInference(
        model: AppleSTTModel,
        audio: AudioData,
        sampleRate: Int,
        language: String?,
        chunkMs: Int,
        realtime: Bool,
        segmentation: STTSegmentationConfig
    ) async throws -> (
        transcript: String,
        totalMs: Double,
        afterStopMs: Double,
        replayStartedAtMs: Int64?,
        replayEndedAtMs: Int64?,
        attempts: [BenchmarkSTTAttempt],
        segmentCount: Int?,
        vadSilenceCount: Int?
    ) {
#if canImport(Speech)
        let chunkSamples = max(1, sampleRate * chunkMs / 1_000)
        let chunkBytes = chunkSamples * MemoryLayout<Int16>.size
        let silenceMs = max(segmentation.silenceMs, 100)
        let maxSegmentMs = max(segmentation.maxSegmentMs, 1_000)
        let preRollMs = max(segmentation.preRollMs, 0)
        let preRollByteLimit = max(0, (sampleRate * preRollMs / 1_000) * MemoryLayout<Int16>.size)

        let replayStartedAtMs = nowEpochMs()
        var replayEndedAtMs = replayStartedAtMs
        var attempts: [BenchmarkSTTAttempt] = []
        var committedSegments: [STTCommittedSegment] = []
        var vadIntervals: [VADInterval] = []

        var preRollBuffer = Data()
        var pendingPreRoll = Data()
        var segmentAudio = Data()
        var segmentStarted = false
        var segmentStartMs: Int64 = 0
        var segmentDurationMs = 0
        var silenceAccumulatedMs = 0
        var segmentHasSpeech = false
        var timelineMs: Int64 = 0
        var activeVADKind: String?
        var activeVADStartMs: Int64 = 0

        func appendPreRoll(_ chunk: Data) {
            guard preRollByteLimit > 0 else {
                return
            }
            preRollBuffer.append(chunk)
            if preRollBuffer.count > preRollByteLimit {
                preRollBuffer = Data(preRollBuffer.suffix(preRollByteLimit))
            }
        }

        func updateVAD(kind: String, startMs: Int64) {
            if activeVADKind == kind {
                return
            }
            if let activeKind = activeVADKind {
                let interval = VADInterval(startMs: activeVADStartMs, endMs: startMs, kind: activeKind)
                if interval.endMs > interval.startMs {
                    vadIntervals.append(interval)
                }
            }
            activeVADKind = kind
            activeVADStartMs = startMs
        }

        func closeVAD(endMs: Int64) {
            guard let activeKind = activeVADKind else {
                return
            }
            let interval = VADInterval(startMs: activeVADStartMs, endMs: endMs, kind: activeKind)
            if interval.endMs > interval.startMs {
                vadIntervals.append(interval)
            }
            activeVADKind = nil
        }

        func ensureSegmentStarted() {
            guard !segmentStarted else {
                return
            }
            let rewind = Int64(min(preRollMs, Int(timelineMs)))
            segmentStartMs = max(0, timelineMs - rewind)
            segmentDurationMs = 0
            silenceAccumulatedMs = 0
            segmentHasSpeech = false
            segmentAudio = pendingPreRoll
            pendingPreRoll.removeAll(keepingCapacity: false)
            segmentStarted = true
        }

        func commitSegment(reason: String, endMs: Int64) async throws {
            guard segmentStarted else {
                return
            }
            let audioForSegment = segmentAudio
            segmentStarted = false
            pendingPreRoll = preRollBuffer
            segmentAudio = Data()
            segmentDurationMs = 0
            silenceAccumulatedMs = 0
            segmentHasSpeech = false

            guard !audioForSegment.isEmpty else {
                return
            }

            let commitStartedAtMs = nowEpochMs()
            let transcript = try await transcribeWithAppleSpeech(
                sampleRate: sampleRate,
                audio: audioForSegment,
                language: language,
                model: model
            )
            let commitEndedAtMs = nowEpochMs()
            attempts.append(BenchmarkSTTAttempt(
                kind: "segment_commit",
                status: .ok,
                startedAtMs: commitStartedAtMs,
                endedAtMs: commitEndedAtMs
            ))

            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                committedSegments.append(STTCommittedSegment(
                    index: committedSegments.count,
                    startMs: segmentStartMs,
                    endMs: max(segmentStartMs, endMs),
                    text: trimmed,
                    reason: reason
                ))
            }
        }

        var offset = 0
        while offset < audio.pcmBytes.count {
            let end = min(offset + chunkBytes, audio.pcmBytes.count)
            let chunk = audio.pcmBytes.subdata(in: offset..<end)
            let durationMs = max(1, chunkDurationMs(byteCount: chunk.count, sampleRate: sampleRate))
            let chunkStartMs = timelineMs
            timelineMs += Int64(durationMs)

            appendPreRoll(chunk)
            ensureSegmentStarted()
            segmentAudio.append(chunk)
            segmentDurationMs += durationMs

            let speech = isSpeechChunk(chunk)
            updateVAD(kind: speech ? "speech" : "silence", startMs: chunkStartMs)
            if speech {
                segmentHasSpeech = true
                silenceAccumulatedMs = 0
            } else {
                silenceAccumulatedMs += durationMs
            }

            if !speech, segmentHasSpeech, silenceAccumulatedMs >= silenceMs {
                try await commitSegment(reason: "silence", endMs: timelineMs)
            } else if segmentDurationMs >= maxSegmentMs {
                try await commitSegment(reason: "max_segment", endMs: timelineMs)
            }

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
        replayEndedAtMs = nowEpochMs()
        attempts.insert(BenchmarkSTTAttempt(
            kind: "stream_send",
            status: .ok,
            startedAtMs: replayStartedAtMs,
            endedAtMs: replayEndedAtMs
        ), at: 0)

        let finalizeStartedAt = DispatchTime.now()
        let finalizeAttemptStartedAtMs = nowEpochMs()
        try await commitSegment(reason: "stop", endMs: timelineMs)
        let finalizeMs = elapsedMs(since: finalizeStartedAt)
        let finalizeAttemptEndedAtMs = nowEpochMs()
        attempts.append(BenchmarkSTTAttempt(
            kind: "stream_finalize",
            status: .ok,
            startedAtMs: finalizeAttemptStartedAtMs,
            endedAtMs: finalizeAttemptEndedAtMs
        ))

        closeVAD(endMs: timelineMs)
        let transcript = committedSegments.map(\.text).joined(separator: "\n")
        let vadSilenceCount = vadIntervals.filter { $0.kind == "silence" }.count
        return (
            transcript,
            Double(max(0, finalizeAttemptEndedAtMs - replayStartedAtMs)),
            finalizeMs,
            replayStartedAtMs,
            replayEndedAtMs,
            attempts,
            committedSegments.count,
            vadSilenceCount
        )
#else
        throw AppError.invalidArgument("この環境では Speech.framework が利用できません")
#endif
    }

    private static func transcribeWithAppleSpeech(
        sampleRate: Int,
        audio: Data,
        language: String?,
        model: AppleSTTModel
    ) async throws -> String {
#if canImport(Speech)
        switch model {
        case .recognizer:
            return try await transcribeWithAppleSpeechRecognizer(
                sampleRate: sampleRate,
                audio: audio,
                language: language
            )
        case .speechTranscriber:
            #if os(macOS)
                if #available(macOS 26.0, *) {
                    return try await transcribeWithSpeechTranscriber(
                        sampleRate: sampleRate,
                        audio: audio,
                        language: language
                    )
                }
                throw AppError.invalidArgument("Apple Speech Transcriber は macOS 26 以降で利用できます")
            #else
                throw AppError.invalidArgument("Apple Speech Transcriber はこのOSで利用できません")
            #endif
        case .dictationTranscriber:
            #if os(macOS)
                if #available(macOS 26.0, *) {
                    return try await transcribeWithDictationTranscriber(
                        sampleRate: sampleRate,
                        audio: audio,
                        language: language
                    )
                }
                throw AppError.invalidArgument("Apple Dictation Transcriber は macOS 26 以降で利用できます")
            #else
                throw AppError.invalidArgument("Apple Dictation Transcriber はこのOSで利用できません")
            #endif
        }
#else
        throw AppError.invalidArgument("この環境では Speech.framework が利用できません")
#endif
    }

#if canImport(Speech)
    private static func transcribeWithAppleSpeechRecognizer(
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> String {
        let recognizer = try await resolveSpeechRecognizer(language: language)

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
    }

    @available(macOS 26.0, *)
    private static func transcribeWithSpeechTranscriber(
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> String {
        let locale = localeForSpeechLanguage(language)
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        return try await transcribeWithSpeechModule(
            sampleRate: sampleRate,
            audio: audio,
            module: module
        ) { result in
            String(result.text.characters)
        }
    }

    @available(macOS 26.0, *)
    private static func transcribeWithDictationTranscriber(
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> String {
        let locale = localeForSpeechLanguage(language)
        let module = DictationTranscriber(locale: locale, preset: .longDictation)
        return try await transcribeWithSpeechModule(
            sampleRate: sampleRate,
            audio: audio,
            module: module
        ) { result in
            String(result.text.characters)
        }
    }

    @available(macOS 26.0, *)
    private static func transcribeWithSpeechModule<Module: SpeechModule>(
        sampleRate: Int,
        audio: Data,
        module: Module,
        extractText: @escaping @Sendable (Module.Result) -> String
    ) async throws -> String {
        let normalizedSampleRate = max(sampleRate, 1)
        let wavData = buildWAVBytes(sampleRate: UInt32(normalizedSampleRate), pcmData: audio)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisp-apple-modern-stt-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try wavData.write(to: tmpURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let audioFile = try AVAudioFile(forReading: tmpURL)
        let analyzer = SpeechAnalyzer(modules: [module])

        let resultsTask = Task<[String], Error> {
            var parts: [String] = []
            for try await result in module.results {
                let text = extractText(result).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    parts.append(text)
                }
            }
            return parts
        }

        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        } catch {
            resultsTask.cancel()
            throw AppError.io("Apple Speech 文字起こしに失敗: \(error.localizedDescription)")
        }
        let parts = try await resultsTask.value
        return normalizedTranscript(parts: parts)
    }

    private static func normalizedTranscript(parts: [String]) -> String {
        var normalized: [String] = []
        normalized.reserveCapacity(parts.count)
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            if normalized.last == trimmed {
                continue
            }
            normalized.append(trimmed)
        }
        return normalized.joined(separator: "\n")
    }

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

    private static func resolveSpeechRecognizer(language: String?) async throws -> SFSpeechRecognizer {
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
        return recognizer
    }

    private final class AppleSpeechStreamingRecognizer: @unchecked Sendable {
        private final class StreamingState: @unchecked Sendable {
            private let lock = NSLock()
            private let sampleRate: Int
            private var request: SFSpeechAudioBufferRecognitionRequest?
            private var task: SFSpeechRecognitionTask?
            private var recognizer: SFSpeechRecognizer?
            private var completed = false
            private var latestTranscript = ""
            private var terminalError: Error?

            init(sampleRate: Int) {
                self.sampleRate = max(sampleRate, 1)
            }

            func activate(
                request: SFSpeechAudioBufferRecognitionRequest,
                task: SFSpeechRecognitionTask,
                recognizer: SFSpeechRecognizer
            ) {
                lock.lock()
                self.request = request
                self.task = task
                self.recognizer = recognizer
                lock.unlock()
            }

            func append(_ chunk: Data) {
                guard !chunk.isEmpty else {
                    return
                }

                let request: SFSpeechAudioBufferRecognitionRequest?
                lock.lock()
                let canAppend = !completed && terminalError == nil
                request = canAppend ? self.request : nil
                lock.unlock()
                guard canAppend, let request else {
                    return
                }

                guard let buffer = makePCMBuffer(from: chunk, sampleRate: sampleRate) else {
                    setTerminalError(AppError.encode("Apple Speech streaming chunk の変換に失敗しました"))
                    return
                }
                request.append(buffer)
            }

            func finish(timeoutNanoseconds: UInt64 = 8_000_000_000) async throws -> String {
                endAudio()
                let started = DispatchTime.now().uptimeNanoseconds
                while true {
                    let snapshot = stateSnapshot()
                    if let error = snapshot.error {
                        throw error
                    }
                    if snapshot.completed {
                        return snapshot.transcript
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now - started >= timeoutNanoseconds {
                        if snapshot.transcript.isEmpty {
                            throw AppError.io("Apple Speech ストリーミング最終結果の待機がタイムアウトしました")
                        }
                        return snapshot.transcript
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }

            func handle(result: SFSpeechRecognitionResult?, error: Error?) {
                if let error {
                    setTerminalError(error)
                    return
                }
                guard let result else {
                    return
                }

                let transcript = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lock.lock()
                if !transcript.isEmpty {
                    latestTranscript = transcript
                }
                if result.isFinal {
                    completed = true
                    request = nil
                    task = nil
                    recognizer = nil
                }
                lock.unlock()
            }

            func cancel() {
                let task: SFSpeechRecognitionTask?
                let request: SFSpeechAudioBufferRecognitionRequest?
                lock.lock()
                task = self.task
                request = self.request
                self.task = nil
                self.request = nil
                recognizer = nil
                completed = true
                lock.unlock()
                request?.endAudio()
                task?.cancel()
            }

            private func setTerminalError(_ error: Error) {
                let task: SFSpeechRecognitionTask?
                lock.lock()
                terminalError = error
                completed = true
                task = self.task
                self.task = nil
                request = nil
                recognizer = nil
                lock.unlock()
                task?.cancel()
            }

            private func stateSnapshot() -> (completed: Bool, transcript: String, error: Error?) {
                lock.lock()
                let snapshot = (completed: completed, transcript: latestTranscript, error: terminalError)
                lock.unlock()
                return snapshot
            }

            private func endAudio() {
                let request: SFSpeechAudioBufferRecognitionRequest?
                lock.lock()
                request = self.request
                lock.unlock()
                request?.endAudio()
            }

            private func makePCMBuffer(from chunk: Data, sampleRate: Int) -> AVAudioPCMBuffer? {
                let usableBytes = chunk.count - (chunk.count % MemoryLayout<Int16>.size)
                guard usableBytes > 0 else {
                    return nil
                }

                guard let format = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: Double(sampleRate),
                    channels: 1,
                    interleaved: false
                ) else {
                    return nil
                }

                let frameCount = AVAudioFrameCount(usableBytes / MemoryLayout<Int16>.size)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                      let channel = buffer.int16ChannelData?.pointee
                else {
                    return nil
                }
                buffer.frameLength = frameCount
                chunk.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else {
                        return
                    }
                    memcpy(channel, base, usableBytes)
                }
                return buffer
            }
        }

        private let state: StreamingState

        init(sampleRate: Int, language: String?) async throws {
            let recognizer = try await BenchmarkExecutor.resolveSpeechRecognizer(language: language)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            let state = StreamingState(sampleRate: sampleRate)
            let task = recognizer.recognitionTask(with: request) { result, error in
                state.handle(result: result, error: error)
            }
            state.activate(request: request, task: task, recognizer: recognizer)
            self.state = state
        }

        func enqueue(_ chunk: Data) async {
            state.append(chunk)
        }

        func finish() async throws -> String {
            defer { state.cancel() }
            let transcript = try await state.finish()
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func parsePairwiseWinner(_ raw: String) throws -> PairwiseWinner {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let winner = PairwiseWinner(rawValue: trimmed) else {
            throw AppError.decode("pairwise winner が不正です: \(raw)")
        }
        return winner
    }
}
