import Foundation

public struct BenchmarkDatasetIntentLabel: Codable, Equatable, Sendable {
    public let intent: String
    public let slots: [String: String]

    public init(intent: String, slots: [String: String] = [:]) {
        self.intent = intent
        self.slots = slots
    }
}

public struct BenchmarkDatasetLabels: Codable, Equatable, Sendable {
    public let transcriptGold: String?
    public let transcriptSilver: String?
    public let intentGold: BenchmarkDatasetIntentLabel?
    public let intentSilver: BenchmarkDatasetIntentLabel?
    public let labelConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case transcriptGold = "transcript_gold"
        case transcriptSilver = "transcript_silver"
        case intentGold = "intent_gold"
        case intentSilver = "intent_silver"
        case labelConfidence = "label_confidence"
    }

    public init(
        transcriptGold: String? = nil,
        transcriptSilver: String? = nil,
        intentGold: BenchmarkDatasetIntentLabel? = nil,
        intentSilver: BenchmarkDatasetIntentLabel? = nil,
        labelConfidence: Double? = nil
    ) {
        self.transcriptGold = transcriptGold
        self.transcriptSilver = transcriptSilver
        self.intentGold = intentGold
        self.intentSilver = intentSilver
        self.labelConfidence = labelConfidence
    }
}

public struct BenchmarkDatasetAccessibilityTextRange: Codable, Equatable, Sendable {
    public let location: Int?
    public let length: Int?

    public init(location: Int? = nil, length: Int? = nil) {
        self.location = location
        self.length = length
    }
}

public struct BenchmarkDatasetAccessibilityFocusedElement: Codable, Equatable, Sendable {
    public let selectedText: String?
    public let selectedRange: BenchmarkDatasetAccessibilityTextRange?
    public let caretContext: String?
    public let caretContextRange: BenchmarkDatasetAccessibilityTextRange?

    public init(
        selectedText: String? = nil,
        selectedRange: BenchmarkDatasetAccessibilityTextRange? = nil,
        caretContext: String? = nil,
        caretContextRange: BenchmarkDatasetAccessibilityTextRange? = nil
    ) {
        self.selectedText = selectedText
        self.selectedRange = selectedRange
        self.caretContext = caretContext
        self.caretContextRange = caretContextRange
    }
}

public struct BenchmarkDatasetAccessibilitySnapshot: Codable, Equatable, Sendable {
    public let focusedElement: BenchmarkDatasetAccessibilityFocusedElement?

    public init(focusedElement: BenchmarkDatasetAccessibilityFocusedElement? = nil) {
        self.focusedElement = focusedElement
    }
}

public struct BenchmarkDatasetCaseRecord: Codable, Equatable, Sendable {
    public let id: String
    public let runID: String?
    public let runDir: String?
    public let audioFile: String?
    public let eventsFile: String?
    public var sttText: String?
    public var outputText: String?
    public var groundTruthText: String?
    public let createdAt: String?
    public let llmModel: String?
    public let appName: String?
    public let context: ContextInfo?
    public let accessibility: BenchmarkDatasetAccessibilitySnapshot?
    public let visionImageFile: String?
    public let visionImageMimeType: String?
    public let intentGold: BenchmarkDatasetIntentLabel?
    public let intentSilver: BenchmarkDatasetIntentLabel?
    public let labelConfidence: Double?
    public let labels: BenchmarkDatasetLabels?

    enum CodingKeys: String, CodingKey {
        case id
        case runID = "run_id"
        case runDir = "run_dir"
        case audioFile = "audio_file"
        case eventsFile = "events_file"
        case sttText = "stt_text"
        case outputText = "output_text"
        case groundTruthText = "ground_truth_text"
        case createdAt = "created_at"
        case llmModel = "llm_model"
        case appName = "app_name"
        case context
        case accessibility
        case visionImageFile = "vision_image_file"
        case visionImageMimeType = "vision_image_mime_type"
        case intentGold = "intent_gold"
        case intentSilver = "intent_silver"
        case labelConfidence = "label_confidence"
        case labels
    }

    public init(
        id: String,
        runID: String? = nil,
        runDir: String? = nil,
        audioFile: String? = nil,
        eventsFile: String? = nil,
        sttText: String? = nil,
        outputText: String? = nil,
        groundTruthText: String? = nil,
        createdAt: String? = nil,
        llmModel: String? = nil,
        appName: String? = nil,
        context: ContextInfo? = nil,
        accessibility: BenchmarkDatasetAccessibilitySnapshot? = nil,
        visionImageFile: String? = nil,
        visionImageMimeType: String? = nil,
        intentGold: BenchmarkDatasetIntentLabel? = nil,
        intentSilver: BenchmarkDatasetIntentLabel? = nil,
        labelConfidence: Double? = nil,
        labels: BenchmarkDatasetLabels? = nil
    ) {
        self.id = id
        self.runID = runID
        self.runDir = runDir
        self.audioFile = audioFile
        self.eventsFile = eventsFile
        self.sttText = sttText
        self.outputText = outputText
        self.groundTruthText = groundTruthText
        self.createdAt = createdAt
        self.llmModel = llmModel
        self.appName = appName
        self.context = context
        self.accessibility = accessibility
        self.visionImageFile = visionImageFile
        self.visionImageMimeType = visionImageMimeType
        self.intentGold = intentGold
        self.intentSilver = intentSilver
        self.labelConfidence = labelConfidence
        self.labels = labels
    }

    public func normalizedReferenceText() -> String? {
        let direct = (groundTruthText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty { return direct }
        let gold = (labels?.transcriptGold ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !gold.isEmpty { return gold }
        let silver = (labels?.transcriptSilver ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !silver.isEmpty { return silver }
        return nil
    }
}

public final class BenchmarkDatasetStore: @unchecked Sendable {
    public init() {}

    public func loadCases(path: String) throws -> [BenchmarkDatasetCaseRecord] {
        let normalizedPath = WhispPaths.normalizeForStorage(path)
        guard !normalizedPath.isEmpty else {
            return []
        }
        guard FileManager.default.fileExists(atPath: normalizedPath) else {
            return []
        }

        let content = try String(contentsOfFile: normalizedPath, encoding: .utf8)
        let decoder = JSONDecoder()
        var results: [BenchmarkDatasetCaseRecord] = []
        for (index, rawLine) in content.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            guard let data = line.data(using: .utf8) else {
                throw AppError.invalidArgument("ケース一覧の読み込みに失敗しました(line=\(index + 1))")
            }
            do {
                let item = try decoder.decode(BenchmarkDatasetCaseRecord.self, from: data)
                results.append(item)
            } catch {
                throw AppError.invalidArgument("ケース一覧JSONLのデコードに失敗しました(line=\(index + 1)): \(error.localizedDescription)")
            }
        }
        return results
    }

    public func saveCases(path: String, records: [BenchmarkDatasetCaseRecord]) throws {
        let normalizedPath = WhispPaths.normalizeForStorage(path)
        guard !normalizedPath.isEmpty else {
            throw AppError.invalidArgument("保存先ケースファイルが不正です。")
        }
        let url = URL(fileURLWithPath: normalizedPath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines: [String] = try records.map { record in
            let data = try encoder.encode(record)
            guard let line = String(data: data, encoding: .utf8) else {
                throw AppError.encode("ケース一覧JSONLのエンコードに失敗しました。")
            }
            return line
        }
        let payload = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try payload.write(to: url, atomically: true, encoding: .utf8)
    }

    public func loadLatestCasesByID(path: String) throws -> [String: BenchmarkDatasetCaseRecord] {
        let all = try loadCases(path: path)
        var latest: [String: BenchmarkDatasetCaseRecord] = [:]
        for record in all {
            latest[record.id] = record
        }
        return latest
    }
}
