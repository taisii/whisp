import Foundation

extension DebugCaptureStore {
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
            "run_dir": record.runDirectoryPath,
            "audio_file": record.audioFilePath,
            "events_file": record.eventsFilePath,
            "stt_text": record.sttText ?? "",
            "output_text": record.outputText ?? "",
            "ground_truth_text": record.groundTruthText ?? "",
            "created_at": record.createdAt,
            "llm_model": record.llmModel,
        ]
        if let audioDuration = audioDurationSeconds(path: record.audioFilePath) {
            payload["audio_duration_sec"] = audioDuration
        }
        if let appName = record.appName {
            payload["app_name"] = appName
        }
        if let context = record.context, !context.isEmpty {
            payload["context"] = [
                "accessibilityText": context.accessibilityText ?? "",
                "windowText": context.windowText ?? "",
                "visionSummary": context.visionSummary ?? "",
                "visionTerms": context.visionTerms,
            ]
        }
        if let accessibilitySnapshot = record.accessibilitySnapshot,
           let accessibilityData = try? JSONEncoder().encode(accessibilitySnapshot),
           let accessibilityJSON = try? JSONSerialization.jsonObject(with: accessibilityData)
        {
            payload["accessibility"] = accessibilityJSON
        }
        if let imagePath = record.visionImageFilePath {
            payload["vision_image_file"] = imagePath
        }
        if let imageMimeType = record.visionImageMimeType {
            payload["vision_image_mime_type"] = imageMimeType
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        try ensureDirectories()
        if !fileManager.fileExists(atPath: manualCasesURL.path) {
            try Data().write(to: manualCasesURL)
        }
        try appendLine(data: data, to: manualCasesURL)
        return manualCasesURL.path
    }
}
