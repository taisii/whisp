import Foundation
import WhispCore

enum STTMode: String {
    case rest
    case stream
}

enum EmitMode: String {
    case discard
    case stdout
    case pbcopy
}

struct PipelineOptions {
    let path: String
    let sttMode: STTMode
    let chunkMs: Int
    let realtime: Bool
    let emitMode: EmitMode
    let contextFilePath: String?
}

struct PipelineRunResult {
    let model: LLMModel
    let sttText: String
    let outputText: String
    let sttSource: String
    let sttSendMs: Double
    let sttFinalizeMs: Double
    let sttTotalMs: Double
    let sttAfterStopMs: Double
    let postMs: Double
    let outputMs: Double
    let totalAfterStopMs: Double
    let totalWallMs: Double
    let audioSeconds: Double
}

struct ManualBenchmarkOptions {
    let jsonlPath: String
    let sttMode: STTMode
    let chunkMs: Int
    let realtime: Bool
    let limit: Int?
    let requireContext: Bool
    let minAudioSeconds: Double
    let benchmarkLogDir: String?
    let intentSource: IntentSource
    let intentJudgeEnabled: Bool
    let intentJudgeModel: LLMModel?
    let minLabelConfidence: Double?
}

enum IntentSource: String {
    case auto
    case gold
    case silver
}

struct IntentLabel: Codable {
    let intent: String
    let slots: [String: String]

    enum CodingKeys: String, CodingKey {
        case intent
        case slots
    }

    init(intent: String, slots: [String: String] = [:]) {
        self.intent = intent
        self.slots = slots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intent = try c.decode(String.self, forKey: .intent)
        slots = (try? c.decode([String: String].self, forKey: .slots)) ?? [:]
    }

    var canonicalJSONString: String {
        let payload: [String: Any] = [
            "intent": intent,
            "slots": slots,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{\"intent\":\"\(intent)\",\"slots\":{}}"
        }
        return text
    }
}

struct ManualBenchmarkLabels: Decodable {
    let transcriptGold: String?
    let transcriptSilver: String?
    let intentGold: IntentLabel?
    let intentSilver: IntentLabel?
    let labelConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case transcriptGold = "transcript_gold"
        case transcriptSilver = "transcript_silver"
        case intentGold = "intent_gold"
        case intentSilver = "intent_silver"
        case labelConfidence = "label_confidence"
    }
}

struct ManualBenchmarkCase: Decodable {
    let id: String
    let runID: String?
    let audioFile: String
    let sttText: String?
    let outputText: String?
    let groundTruthText: String?
    let createdAt: String?
    let llmModel: String?
    let appName: String?
    let context: ContextInfo?
    let visionImageFile: String?
    let visionImageMimeType: String?
    let intentGold: IntentLabel?
    let intentSilver: IntentLabel?
    let labelConfidence: Double?
    let labels: ManualBenchmarkLabels?

    enum CodingKeys: String, CodingKey {
        case id
        case runID = "run_id"
        case audioFile = "audio_file"
        case sttText = "stt_text"
        case outputText = "output_text"
        case groundTruthText = "ground_truth_text"
        case createdAt = "created_at"
        case llmModel = "llm_model"
        case appName = "app_name"
        case context
        case visionImageFile = "vision_image_file"
        case visionImageMimeType = "vision_image_mime_type"
        case intentGold = "intent_gold"
        case intentSilver = "intent_silver"
        case labelConfidence = "label_confidence"
        case labels
    }

    func resolvedReferenceTranscript() -> (text: String, source: String)? {
        let direct = (groundTruthText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty {
            return (direct, "ground_truth_text")
        }
        let gold = (labels?.transcriptGold ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !gold.isEmpty {
            return (gold, "labels.transcript_gold")
        }
        let silver = (labels?.transcriptSilver ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !silver.isEmpty {
            return (silver, "labels.transcript_silver")
        }
        return nil
    }

    func resolvedSTTReferenceTranscript() -> (text: String, source: String)? {
        let gold = (labels?.transcriptGold ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !gold.isEmpty {
            return (gold, "labels.transcript_gold")
        }
        let stt = (sttText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stt.isEmpty {
            return (stt, "stt_text")
        }
        let silver = (labels?.transcriptSilver ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !silver.isEmpty {
            return (silver, "labels.transcript_silver")
        }
        let direct = (groundTruthText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty {
            return (direct, "ground_truth_text")
        }
        return nil
    }

    func resolvedGenerationInputSTT() -> (text: String, source: String)? {
        let stt = (sttText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stt.isEmpty {
            return (stt, "stt_text")
        }
        let gold = (labels?.transcriptGold ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !gold.isEmpty {
            return (gold, "labels.transcript_gold")
        }
        let silver = (labels?.transcriptSilver ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !silver.isEmpty {
            return (silver, "labels.transcript_silver")
        }
        return nil
    }

    func resolvedGenerationReferenceText() -> (text: String, source: String)? {
        let direct = (groundTruthText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty {
            return (direct, "ground_truth_text")
        }
        let gold = (labels?.transcriptGold ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !gold.isEmpty {
            return (gold, "labels.transcript_gold")
        }
        let silver = (labels?.transcriptSilver ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !silver.isEmpty {
            return (silver, "labels.transcript_silver")
        }
        return nil
    }

    func resolvedVisionReference() -> (summary: String, terms: [String])? {
        guard let context else { return nil }
        let summary = (context.visionSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = context.visionTerms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if summary.isEmpty, terms.isEmpty {
            return nil
        }
        return (summary, terms)
    }

    func resolvedLabelConfidence() -> Double? {
        if let labelConfidence {
            return labelConfidence
        }
        return labels?.labelConfidence
    }

    func resolvedReferenceIntent(source: IntentSource) -> (label: IntentLabel, source: String)? {
        switch source {
        case .gold:
            if let intentGold {
                return (intentGold, "intent_gold")
            }
            if let intent = labels?.intentGold {
                return (intent, "labels.intent_gold")
            }
            return nil
        case .silver:
            if let intentSilver {
                return (intentSilver, "intent_silver")
            }
            if let intent = labels?.intentSilver {
                return (intent, "labels.intent_silver")
            }
            return nil
        case .auto:
            if let intentGold {
                return (intentGold, "intent_gold")
            }
            if let intent = labels?.intentGold {
                return (intent, "labels.intent_gold")
            }
            if let intentSilver {
                return (intentSilver, "intent_silver")
            }
            if let intent = labels?.intentSilver {
                return (intent, "labels.intent_silver")
            }
            return nil
        }
    }
}

struct ManualCaseEvaluation {
    let id: String
    let contextUsed: Bool
    let visionImageAttached: Bool
    let exactMatch: Bool
    let cer: Double
    let gtChars: Int
    let editDistance: Int
    let sttAfterStopMs: Double
    let postMs: Double
    let totalAfterStopMs: Double
    let audioSeconds: Double
    let transcriptSource: String
    let intentReferenceSource: String?
    let intentMatch: Bool?
    let intentScore: Int?
}

struct IntentJudgeResult {
    let match: Bool
    let score: Int
}

struct IntentJudgeResponse: Decodable {
    let match: Bool
    let score: Int
    let errorType: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case match
        case score
        case errorType = "error_type"
        case reason
    }
}

struct ManualCaseLogRow: Encodable {
    let id: String
    let status: String
    let reason: String?
    let suitable: Bool
    let audioSeconds: Double?
    let contextUsed: Bool
    let visionImageAttached: Bool
    let transcriptReferenceSource: String?
    let exactMatch: Bool?
    let cer: Double?
    let intentReferenceSource: String?
    let intentMatch: Bool?
    let intentScore: Int?
    let sttAfterStopMs: Double?
    let postMs: Double?
    let totalAfterStopMs: Double?
}

struct ManualBenchmarkSummaryLog: Encodable {
    let generatedAt: String
    let jsonlPath: String
    let sttMode: String
    let chunkMs: Int
    let realtime: Bool
    let requireContext: Bool
    let minAudioSeconds: Double
    let minLabelConfidence: Double?
    let intentSource: String
    let intentJudgeEnabled: Bool
    let intentJudgeModel: String?
    let casesTotal: Int
    let casesSelected: Int
    let executedCases: Int
    let skippedMissingAudio: Int
    let skippedInvalidAudio: Int
    let skippedMissingReferenceTranscript: Int
    let skippedMissingContext: Int
    let skippedTooShortAudio: Int
    let skippedLowLabelConfidence: Int
    let failedRuns: Int
    let exactMatchCases: Int
    let exactMatchRate: Double
    let avgCER: Double
    let weightedCER: Double
    let intentEvaluatedCases: Int
    let intentMatchCases: Int
    let intentMatchRate: Double?
    let intentAvgScore: Double?
    let avgSttAfterStopMs: Double
    let avgPostMs: Double
    let avgTotalAfterStopMs: Double
}

struct ManualBenchmarkLogPaths {
    let baseDir: String
    let caseRowsPath: String
    let summaryPath: String
}

struct VisionBenchmarkOptions {
    let jsonlPath: String
    let limit: Int?
    let benchmarkLogDir: String?
    let useCache: Bool
}

struct STTBenchmarkOptions {
    let jsonlPath: String
    let sttMode: STTMode
    let chunkMs: Int
    let realtime: Bool
    let limit: Int?
    let minAudioSeconds: Double
    let benchmarkLogDir: String?
    let useCache: Bool
}

struct GenerationBenchmarkOptions {
    let jsonlPath: String
    let limit: Int?
    let requireContext: Bool
    let benchmarkLogDir: String?
    let useCache: Bool
}

struct VisionCaseLogRow: Encodable {
    let id: String
    let status: String
    let reason: String?
    let cached: Bool
    let summaryCER: Double?
    let termsPrecision: Double?
    let termsRecall: Double?
    let termsF1: Double?
    let latencyMs: Double?
}

struct STTCaseLogRow: Encodable {
    let id: String
    let status: String
    let reason: String?
    let cached: Bool
    let transcriptReferenceSource: String?
    let exactMatch: Bool?
    let cer: Double?
    let sttTotalMs: Double?
    let sttAfterStopMs: Double?
    let audioSeconds: Double?
}

struct GenerationCaseLogRow: Encodable {
    let id: String
    let status: String
    let reason: String?
    let cached: Bool
    let inputSource: String?
    let referenceSource: String?
    let exactMatch: Bool?
    let cer: Double?
    let postMs: Double?
    let outputChars: Int?
}

struct ComponentSummaryLog: Encodable {
    let generatedAt: String
    let benchmark: String
    let jsonlPath: String
    let casesTotal: Int
    let casesSelected: Int
    let executedCases: Int
    let skippedCases: Int
    let failedCases: Int
    let cachedHits: Int
    let exactMatchRate: Double?
    let avgCER: Double?
    let weightedCER: Double?
    let avgLatencyMs: Double?
    let avgAfterStopMs: Double?
    let avgTermsF1: Double?
}

struct ComponentBenchmarkLogPaths {
    let baseDir: String
    let rowsPath: String
    let summaryPath: String
}

struct CachedVisionResult: Codable {
    let key: String
    let model: String
    let summary: String
    let terms: [String]
    let latencyMs: Double
    let createdAt: String
}

struct CachedSTTResult: Codable {
    let key: String
    let mode: String
    let transcript: String
    let totalMs: Double
    let afterStopMs: Double
    let createdAt: String
}

struct CachedGenerationResult: Codable {
    let key: String
    let model: String
    let output: String
    let postMs: Double
    let createdAt: String
}

struct TermScore {
    let precision: Double
    let recall: Double
    let f1: Double
}

struct GeminiTextPart: Encodable {
    let text: String
}

struct GeminiTextContent: Encodable {
    let role: String
    let parts: [GeminiTextPart]
}

struct GeminiTextRequest: Encodable {
    let contents: [GeminiTextContent]
}

struct OpenAITextMessage: Encodable {
    let role: String
    let content: String
}

struct OpenAITextRequest: Encodable {
    let model: String
    let messages: [OpenAITextMessage]
}
