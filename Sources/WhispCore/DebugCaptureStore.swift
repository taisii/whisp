import Foundation

public struct DebugPromptSnapshot: Codable, Equatable, Sendable {
    public let stage: String
    public let model: String
    public let promptChars: Int
    public let promptFilePath: String
    public let metaFilePath: String
    public let contextSummaryChars: Int
    public let contextTermsCount: Int
    public let contextAccessibilityChars: Int
    public let promptText: String

    public init(
        stage: String,
        model: String,
        promptChars: Int,
        promptFilePath: String,
        metaFilePath: String,
        contextSummaryChars: Int,
        contextTermsCount: Int,
        contextAccessibilityChars: Int,
        promptText: String
    ) {
        self.stage = stage
        self.model = model
        self.promptChars = promptChars
        self.promptFilePath = promptFilePath
        self.metaFilePath = metaFilePath
        self.contextSummaryChars = contextSummaryChars
        self.contextTermsCount = contextTermsCount
        self.contextAccessibilityChars = contextAccessibilityChars
        self.promptText = promptText
    }
}

public struct DebugCaptureRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let runID: String
    public let createdAt: String
    public let audioFilePath: String
    public let sampleRate: Int

    public var sttText: String?
    public var outputText: String?
    public var llmModel: String
    public var appName: String?
    public var status: String
    public var errorMessage: String?
    public var groundTruthText: String?
    public var context: ContextInfo?
    public var visionImageFilePath: String?
    public var visionImageMimeType: String?

    public init(
        id: String,
        runID: String,
        createdAt: String,
        audioFilePath: String,
        sampleRate: Int,
        sttText: String? = nil,
        outputText: String? = nil,
        llmModel: String,
        appName: String?,
        status: String,
        errorMessage: String? = nil,
        groundTruthText: String? = nil,
        context: ContextInfo? = nil,
        visionImageFilePath: String? = nil,
        visionImageMimeType: String? = nil
    ) {
        self.id = id
        self.runID = runID
        self.createdAt = createdAt
        self.audioFilePath = audioFilePath
        self.sampleRate = sampleRate
        self.sttText = sttText
        self.outputText = outputText
        self.llmModel = llmModel
        self.appName = appName
        self.status = status
        self.errorMessage = errorMessage
        self.groundTruthText = groundTruthText
        self.context = context
        self.visionImageFilePath = visionImageFilePath
        self.visionImageMimeType = visionImageMimeType
    }
}

public struct DebugCaptureDetails: Sendable {
    public let record: DebugCaptureRecord
    public let prompts: [DebugPromptSnapshot]

    public init(record: DebugCaptureRecord, prompts: [DebugPromptSnapshot]) {
        self.record = record
        self.prompts = prompts
    }
}

public final class DebugCaptureStore: @unchecked Sendable {
    public static let shared = DebugCaptureStore()

    private let lock = NSLock()
    private let fileManager = FileManager.default

    private let baseURL: URL
    private let capturesURL: URL
    private let promptsURL: URL
    private let manualCasesURL: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = environment["HOME"] ?? NSTemporaryDirectory()
        baseURL = URL(fileURLWithPath: home)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("whisp", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
        capturesURL = baseURL.appendingPathComponent("captures", isDirectory: true)
        promptsURL = baseURL.appendingPathComponent("prompts", isDirectory: true)
        manualCasesURL = baseURL.appendingPathComponent("manual_test_cases.jsonl", isDirectory: false)
    }

    public var capturesDirectoryPath: String { capturesURL.path }
    public var promptsDirectoryPath: String { promptsURL.path }
    public var manualCasesPath: String { manualCasesURL.path }

    @discardableResult
    public func saveRecording(
        runID: String,
        sampleRate: Int,
        pcmData: Data,
        llmModel: String,
        appName: String?
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectories()

        let id = "\(timestampToken())-\(runID)"
        let wavPath = capturesURL.appendingPathComponent("\(id).wav", isDirectory: false)
        let jsonPath = capturesURL.appendingPathComponent("\(id).json", isDirectory: false)

        let wav = buildWAVBytes(sampleRate: UInt32(max(sampleRate, 1)), pcmData: pcmData)
        try wav.write(to: wavPath, options: [.atomic])

        let record = DebugCaptureRecord(
            id: id,
            runID: runID,
            createdAt: isoNow(),
            audioFilePath: wavPath.path,
            sampleRate: sampleRate,
            llmModel: llmModel,
            appName: appName,
            status: "recorded"
        )
        try writeRecord(record, to: jsonPath)
        return id
    }

    public func updateResult(
        captureID: String,
        sttText: String?,
        outputText: String?,
        status: String,
        errorMessage: String? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let path = recordPath(captureID: captureID)
        guard var record = try loadRecord(path: path) else { return }
        record.sttText = sttText
        record.outputText = outputText
        record.status = status
        record.errorMessage = errorMessage
        try writeRecord(record, to: path)
    }

    public func setGroundTruth(captureID: String, text: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let path = recordPath(captureID: captureID)
        guard var record = try loadRecord(path: path) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        record.groundTruthText = trimmed.isEmpty ? nil : trimmed
        try writeRecord(record, to: path)
    }

    public func saveVisionArtifacts(
        captureID: String,
        context: ContextInfo?,
        imageData: Data?,
        imageMimeType: String?
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let path = recordPath(captureID: captureID)
        guard var record = try loadRecord(path: path) else { return }

        record.context = context
        if let imageData, !imageData.isEmpty {
            try ensureDirectories()
            let ext = imageExtension(for: imageMimeType)
            let imagePath = capturesURL.appendingPathComponent("\(captureID).vision.\(ext)", isDirectory: false)
            try imageData.write(to: imagePath, options: [.atomic])
            record.visionImageFilePath = imagePath.path
            record.visionImageMimeType = imageMimeType ?? (ext == "png" ? "image/png" : "image/jpeg")
        }
        try writeRecord(record, to: path)
    }

    public func deleteCapture(captureID: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let path = recordPath(captureID: captureID)
        guard let record = try loadRecord(path: path) else { return }

        if fileManager.fileExists(atPath: record.audioFilePath) {
            try fileManager.removeItem(atPath: record.audioFilePath)
        }
        if let visionImageFilePath = record.visionImageFilePath,
           fileManager.fileExists(atPath: visionImageFilePath)
        {
            try fileManager.removeItem(atPath: visionImageFilePath)
        }
        if fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
        }
    }

    public func listRecords(limit: Int = 100) throws -> [DebugCaptureRecord] {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectories()
        let files = try fileManager.contentsOfDirectory(at: capturesURL, includingPropertiesForKeys: nil)
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        let decoded: [DebugCaptureRecord] = try jsonFiles.compactMap { try loadRecord(path: $0) }
        let sorted = decoded.sorted { $0.createdAt > $1.createdAt }
        return Array(sorted.prefix(max(1, limit)))
    }

    public func loadDetails(captureID: String) throws -> DebugCaptureDetails? {
        lock.lock()
        defer { lock.unlock() }

        guard let record = try loadRecord(path: recordPath(captureID: captureID)) else {
            return nil
        }
        let prompts = try loadPromptSnapshots(runID: record.runID)
        return DebugCaptureDetails(record: record, prompts: prompts)
    }

    @discardableResult
    public func appendManualTestCase(captureID: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let record = try loadRecord(path: recordPath(captureID: captureID)) else {
            throw AppError.invalidArgument("capture not found: \(captureID)")
        }

        var payload: [String: Any] = [
            "id": record.id,
            "run_id": record.runID,
            "audio_file": record.audioFilePath,
            "stt_text": record.sttText ?? "",
            "output_text": record.outputText ?? "",
            "ground_truth_text": record.groundTruthText ?? "",
            "created_at": record.createdAt,
            "llm_model": record.llmModel,
        ]
        if let appName = record.appName {
            payload["app_name"] = appName
        }
        if let context = record.context, !context.isEmpty {
            payload["context"] = [
                "accessibilityText": context.accessibilityText ?? "",
                "visionSummary": context.visionSummary ?? "",
                "visionTerms": context.visionTerms,
            ]
        }
        if let imagePath = record.visionImageFilePath {
            payload["vision_image_file"] = imagePath
        }
        if let imageMimeType = record.visionImageMimeType {
            payload["vision_image_mime_type"] = imageMimeType
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let line = String(data: data, encoding: .utf8)! + "\n"

        try ensureDirectories()
        if !fileManager.fileExists(atPath: manualCasesURL.path) {
            try Data().write(to: manualCasesURL)
        }
        guard let handle = try? FileHandle(forWritingTo: manualCasesURL) else {
            throw AppError.io("manual case file open failed")
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let lineData = line.data(using: .utf8) {
            try handle.write(contentsOf: lineData)
        }
        return manualCasesURL.path
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: capturesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: promptsURL, withIntermediateDirectories: true)
    }

    private func recordPath(captureID: String) -> URL {
        capturesURL.appendingPathComponent("\(captureID).json", isDirectory: false)
    }

    private func loadRecord(path: URL) throws -> DebugCaptureRecord? {
        guard fileManager.fileExists(atPath: path.path) else {
            return nil
        }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(DebugCaptureRecord.self, from: data)
    }

    private func writeRecord(_ record: DebugCaptureRecord, to path: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: path, options: [.atomic])
    }

    private func loadPromptSnapshots(runID: String) throws -> [DebugPromptSnapshot] {
        guard fileManager.fileExists(atPath: promptsURL.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(at: promptsURL, includingPropertiesForKeys: nil)
        let metaFiles = files.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix(".meta.json") }
        var snapshots: [DebugPromptSnapshot] = []

        for metaURL in metaFiles {
            guard let metaData = try? Data(contentsOf: metaURL),
                  let record = try? JSONDecoder().decode(PromptTraceRecord.self, from: metaData)
            else {
                continue
            }

            let metaRunID = record.extra["run_id"] ?? ""
            if metaRunID != runID {
                continue
            }

            let promptURL = promptsURL.appendingPathComponent(record.promptFile, isDirectory: false)
            let promptText = (try? String(contentsOf: promptURL, encoding: .utf8)) ?? ""
            let summaryChars = record.context?.visionSummary?.count ?? 0
            let termsCount = record.context?.visionTerms.count ?? 0
            let accessibilityChars = record.context?.accessibilityText?.count ?? 0

            snapshots.append(
                DebugPromptSnapshot(
                    stage: record.stage,
                    model: record.model,
                    promptChars: record.promptChars,
                    promptFilePath: promptURL.path,
                    metaFilePath: metaURL.path,
                    contextSummaryChars: summaryChars,
                    contextTermsCount: termsCount,
                    contextAccessibilityChars: accessibilityChars,
                    promptText: promptText
                )
            )
        }

        return snapshots.sorted { $0.metaFilePath > $1.metaFilePath }
    }

    private func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func timestampToken() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func imageExtension(for mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "image/png":
            return "png"
        default:
            return "jpg"
        }
    }
}
