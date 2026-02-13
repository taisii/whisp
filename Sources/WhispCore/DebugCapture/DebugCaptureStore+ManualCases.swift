import Foundation

extension DebugCaptureStore {
    private struct ManualCaseLabels: Codable {
        let transcriptGold: String

        enum CodingKeys: String, CodingKey {
            case transcriptGold = "transcript_gold"
        }
    }

    private struct ManualCasePayload: Codable {
        let id: String
        let runID: String
        let runDir: String
        let audioFile: String
        let eventsFile: String
        let sttText: String
        let outputText: String
        let groundTruthText: String
        let createdAt: String
        let llmModel: String
        let audioDurationSec: Double?
        let appName: String?
        let context: ContextInfo?
        let accessibility: AccessibilitySnapshot?
        let visionImageFile: String?
        let visionImageMimeType: String?
        let labels: ManualCaseLabels?

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
            case audioDurationSec = "audio_duration_sec"
            case appName = "app_name"
            case context
            case accessibility
            case visionImageFile = "vision_image_file"
            case visionImageMimeType = "vision_image_mime_type"
            case labels
        }
    }

    @discardableResult
    public func appendManualTestCase(captureID: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let record = try loadRecord(path: recordPath(captureID: captureID)) else {
            throw AppError.invalidArgument("capture not found: \(captureID)")
        }

        try ensureDirectories()
        try fileManager.createDirectory(at: manualCaseAssetsURL, withIntermediateDirectories: true)
        let caseAssetsDirectory = manualCaseAssetsURL.appendingPathComponent(record.id, isDirectory: true)
        try fileManager.createDirectory(at: caseAssetsDirectory, withIntermediateDirectories: true)

        let copiedAudioPath = try copyCaseAsset(
            sourcePath: record.audioFilePath,
            destinationDirectory: caseAssetsDirectory,
            destinationBaseName: "audio",
            fallbackExtension: "wav",
            required: true
        )
        guard let copiedAudioPath else {
            throw AppError.invalidArgument("audio file の固定化に失敗しました")
        }
        let copiedVisionPath = try copyCaseAsset(
            sourcePath: record.visionImageFilePath,
            destinationDirectory: caseAssetsDirectory,
            destinationBaseName: "vision",
            fallbackExtension: imageExtension(for: record.visionImageMimeType, sourcePath: record.visionImageFilePath),
            required: false
        )

        let sttGroundTruth = record.sttGroundTruthText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payload = ManualCasePayload(
            id: record.id,
            runID: record.runID,
            runDir: record.runDirectoryPath,
            audioFile: copiedAudioPath,
            eventsFile: record.eventsFilePath,
            sttText: record.sttText ?? "",
            outputText: record.outputText ?? "",
            groundTruthText: record.groundTruthText ?? "",
            createdAt: record.createdAt,
            llmModel: record.llmModel,
            audioDurationSec: audioDurationSeconds(path: copiedAudioPath),
            appName: record.appName,
            context: normalizedContext(record.context),
            accessibility: record.accessibilitySnapshot,
            visionImageFile: copiedVisionPath,
            visionImageMimeType: copiedVisionPath == nil ? nil : record.visionImageMimeType,
            labels: sttGroundTruth.isEmpty ? nil : ManualCaseLabels(transcriptGold: sttGroundTruth)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)

        if !fileManager.fileExists(atPath: manualCasesURL.path) {
            try Data().write(to: manualCasesURL)
        }
        try appendLine(data: data, to: manualCasesURL)
        return manualCasesURL.path
    }

    private func normalizedContext(_ context: ContextInfo?) -> ContextInfo? {
        guard let context, !context.isEmpty else {
            return nil
        }
        return ContextInfo(
            accessibilityText: context.accessibilityText ?? "",
            windowText: context.windowText ?? "",
            visionSummary: context.visionSummary ?? "",
            visionTerms: context.visionTerms
        )
    }

    private func copyCaseAsset(
        sourcePath: String?,
        destinationDirectory: URL,
        destinationBaseName: String,
        fallbackExtension: String,
        required: Bool
    ) throws -> String? {
        let trimmedSource = (sourcePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSource.isEmpty {
            if required {
                throw AppError.invalidArgument("\(destinationBaseName) file path がありません")
            }
            return nil
        }

        let sourceURL = URL(fileURLWithPath: trimmedSource, isDirectory: false)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            if required {
                throw AppError.invalidArgument("\(destinationBaseName) file が見つかりません: \(sourceURL.path)")
            }
            return nil
        }

        let ext = normalizedAssetExtension(sourceURL.pathExtension, fallback: fallbackExtension)
        let destinationURL = destinationDirectory
            .appendingPathComponent(destinationBaseName, isDirectory: false)
            .appendingPathExtension(ext)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL.path
    }

    private func normalizedAssetExtension(_ ext: String, fallback: String) -> String {
        let trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmed.isEmpty {
            return trimmed
        }
        let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return fallbackTrimmed.isEmpty ? "dat" : fallbackTrimmed
    }
}
