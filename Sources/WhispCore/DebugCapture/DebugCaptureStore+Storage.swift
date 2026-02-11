import Foundation

extension DebugCaptureStore {
    func ensureDirectories() throws {
        try fileManager.createDirectory(at: runsURL, withIntermediateDirectories: true)
    }

    func runDirectory(captureID: String) -> URL {
        runsURL.appendingPathComponent(captureID, isDirectory: true)
    }

    func recordPath(captureID: String) -> URL {
        runDirectory(captureID: captureID).appendingPathComponent("manifest.json", isDirectory: false)
    }

    func loadRecord(path: URL) throws -> DebugCaptureRecord? {
        guard fileManager.fileExists(atPath: path.path) else {
            return nil
        }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(DebugCaptureRecord.self, from: data)
    }

    func writeRecord(_ record: DebugCaptureRecord, to path: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: path, options: [.atomic])
    }

    func appendLine(data: Data, to path: URL) throws {
        if !fileManager.fileExists(atPath: path.path) {
            try Data().write(to: path)
        }
        guard let handle = try? FileHandle(forWritingTo: path) else {
            throw AppError.io("log file open failed: \(path.path)")
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    func loadPromptSnapshots(promptsDirectoryPath: String) throws -> [DebugPromptSnapshot] {
        let promptsURL = URL(fileURLWithPath: promptsDirectoryPath, isDirectory: true)
        guard fileManager.fileExists(atPath: promptsURL.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(
            at: promptsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let traceDirectories = files.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        var snapshots: [DebugPromptSnapshot] = []

        for traceDirectory in traceDirectories {
            let requestMetaURL = traceDirectory.appendingPathComponent("request.json", isDirectory: false)
            let requestTextURL = traceDirectory.appendingPathComponent("request.txt", isDirectory: false)
            let responseTextURL = traceDirectory.appendingPathComponent("response.txt", isDirectory: false)

            guard let metaData = try? Data(contentsOf: requestMetaURL),
                  let trace = try? JSONDecoder().decode(PromptTraceRequestRecord.self, from: metaData)
            else {
                continue
            }

            let promptText = (try? String(contentsOf: requestTextURL, encoding: .utf8)) ?? ""
            let responseText = (try? String(contentsOf: responseTextURL, encoding: .utf8)) ?? ""
            let summaryChars = trace.context?.visionSummary?.count ?? 0
            let termsCount = trace.context?.visionTerms.count ?? 0
            let accessibilityChars = (trace.context?.accessibilityText?.count ?? 0)
                + (trace.context?.windowText?.count ?? 0)

            snapshots.append(
                DebugPromptSnapshot(
                    stage: trace.stage,
                    model: trace.model,
                    promptChars: trace.requestChars,
                    promptFilePath: requestTextURL.path,
                    metaFilePath: requestMetaURL.path,
                    contextSummaryChars: summaryChars,
                    contextTermsCount: termsCount,
                    contextAccessibilityChars: accessibilityChars,
                    context: trace.context,
                    promptText: promptText,
                    responseText: responseText
                )
            )
        }

        return snapshots.sorted { $0.promptFilePath > $1.promptFilePath }
    }

    func isoNow() -> String {
        isoString(Date())
    }

    func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func timestampToken() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    func imageExtension(for mimeType: String?, sourcePath: String? = nil) -> String {
        switch mimeType?.lowercased() {
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        default:
            let ext = (sourcePath as NSString?)?.pathExtension.lowercased() ?? ""
            switch ext {
            case "png", "jpg", "jpeg", "webp":
                return ext == "jpeg" ? "jpg" : ext
            default:
                return "jpg"
            }
        }
    }

    func audioDurationSeconds(path: String) -> Double? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let audio = try? parsePCM16MonoWAV(data)
        else {
            return nil
        }
        return Double(audio.durationSeconds)
    }
}
