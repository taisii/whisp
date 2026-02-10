import Foundation

extension DebugCaptureStore {
    @discardableResult
    public func saveRecording(
        runID: String,
        sampleRate: Int,
        pcmData: Data,
        llmModel: String,
        appName: String?,
        accessibilitySnapshot: AccessibilitySnapshot? = nil
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectories()

        let id = "\(timestampToken())-\(runID)"
        let runDir = runDirectory(captureID: id)
        let promptsDir = runDir.appendingPathComponent("prompts", isDirectory: true)
        let audioPath = runDir.appendingPathComponent("audio.wav", isDirectory: false)
        let eventsPath = runDir.appendingPathComponent("events.jsonl", isDirectory: false)
        let manifestPath = runDir.appendingPathComponent("manifest.json", isDirectory: false)

        try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: promptsDir, withIntermediateDirectories: true)

        let wav = buildWAVBytes(sampleRate: UInt32(max(sampleRate, 1)), pcmData: pcmData)
        try wav.write(to: audioPath, options: [.atomic])
        try Data().write(to: eventsPath, options: [.atomic])

        let record = DebugCaptureRecord(
            id: id,
            runID: runID,
            createdAt: isoNow(),
            runDirectoryPath: runDir.path,
            promptsDirectoryPath: promptsDir.path,
            eventsFilePath: eventsPath.path,
            audioFilePath: audioPath.path,
            sampleRate: sampleRate,
            llmModel: llmModel,
            appName: appName,
            status: "recorded",
            accessibilitySnapshot: accessibilitySnapshot
        )
        try writeRecord(record, to: manifestPath)
        return id
    }

    public func appendEvent(captureID: String, event: String, fields: [String: String] = [:]) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let record = try loadRecord(path: recordPath(captureID: captureID)) else { return }
        let payload = DebugRunEvent(timestamp: isoNow(), event: event, fields: fields)
        let data = try JSONEncoder().encode(payload)
        try appendLine(data: data, to: URL(fileURLWithPath: record.eventsFilePath))
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
            let ext = imageExtension(for: imageMimeType)
            let imagePath = runDirectory(captureID: captureID).appendingPathComponent("vision.\(ext)", isDirectory: false)
            try imageData.write(to: imagePath, options: [.atomic])
            record.visionImageFilePath = imagePath.path
            record.visionImageMimeType = imageMimeType ?? (ext == "png" ? "image/png" : "image/jpeg")
        }
        try writeRecord(record, to: path)
    }

    public func deleteCapture(captureID: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let runDir = runDirectory(captureID: captureID)
        guard fileManager.fileExists(atPath: runDir.path) else { return }
        try fileManager.removeItem(at: runDir)
    }

    public func listRecords(limit: Int = 100) throws -> [DebugCaptureRecord] {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectories()
        let entries = try fileManager.contentsOfDirectory(at: runsURL, includingPropertiesForKeys: nil)
        var records: [DebugCaptureRecord] = []

        for entry in entries {
            let manifest = entry.appendingPathComponent("manifest.json", isDirectory: false)
            guard let record = try loadRecord(path: manifest) else { continue }
            records.append(record)
        }

        let sorted = records.sorted { $0.createdAt > $1.createdAt }
        return Array(sorted.prefix(max(1, limit)))
    }

    public func loadDetails(captureID: String) throws -> DebugCaptureDetails? {
        lock.lock()
        defer { lock.unlock() }

        guard let record = try loadRecord(path: recordPath(captureID: captureID)) else {
            return nil
        }
        let prompts = try loadPromptSnapshots(promptsDirectoryPath: record.promptsDirectoryPath)
        return DebugCaptureDetails(record: record, prompts: prompts)
    }

    public func runDirectoryPath(captureID: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let record = try loadRecord(path: recordPath(captureID: captureID)) else {
            return nil
        }
        return record.runDirectoryPath
    }
}
