import Foundation

extension DebugCaptureStore {
    @discardableResult
    public func reserveRun(
        runID: String,
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
        if !fileManager.fileExists(atPath: eventsPath.path) {
            try Data().write(to: eventsPath, options: [.atomic])
        }

        let record = DebugCaptureRecord(
            id: id,
            runID: runID,
            createdAt: isoNow(),
            runDirectoryPath: runDir.path,
            promptsDirectoryPath: promptsDir.path,
            eventsFilePath: eventsPath.path,
            audioFilePath: audioPath.path,
            sampleRate: 0,
            texts: DebugRunTexts(),
            metrics: DebugRunMetrics(),
            artifacts: DebugRunArtifactsSummary(
                audioFile: "audio.wav",
                eventsFile: "events.jsonl",
                promptsDirectory: "prompts",
                visionImageFile: nil,
                visionImageMimeType: nil
            ),
            llmModel: llmModel,
            appName: appName,
            status: "recording",
            accessibilitySnapshot: accessibilitySnapshot
        )
        try writeRecord(record, to: manifestPath)
        return id
    }

    @discardableResult
    public func saveRecording(
        runID: String,
        sampleRate: Int,
        pcmData: Data,
        llmModel: String,
        appName: String?,
        captureID: String? = nil,
        accessibilitySnapshot: AccessibilitySnapshot? = nil
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectories()

        let id = captureID ?? "\(timestampToken())-\(runID)"
        let runDir = runDirectory(captureID: id)
        let promptsDir = runDir.appendingPathComponent("prompts", isDirectory: true)
        let audioPath = runDir.appendingPathComponent("audio.wav", isDirectory: false)
        let eventsPath = runDir.appendingPathComponent("events.jsonl", isDirectory: false)
        let manifestPath = runDir.appendingPathComponent("manifest.json", isDirectory: false)

        try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: eventsPath.path) {
            try Data().write(to: eventsPath, options: [.atomic])
        }

        if !pcmData.isEmpty {
            let wav = buildWAVBytes(sampleRate: UInt32(max(sampleRate, 1)), pcmData: pcmData)
            try wav.write(to: audioPath, options: [.atomic])
        }

        let record: DebugCaptureRecord
        if let existing = try loadRecord(path: manifestPath) {
            record = DebugCaptureRecord(
                schemaVersion: existing.schemaVersion,
                id: existing.id,
                runID: existing.runID,
                createdAt: existing.createdAt,
                runDirectoryPath: existing.runDirectoryPath,
                promptsDirectoryPath: existing.promptsDirectoryPath,
                eventsFilePath: existing.eventsFilePath,
                audioFilePath: existing.audioFilePath,
                sampleRate: sampleRate,
                skipReason: existing.skipReason,
                failure: existing.failure,
                texts: existing.texts,
                metrics: existing.metrics,
                artifacts: existing.artifacts,
                sttText: existing.sttText,
                outputText: existing.outputText,
                llmModel: llmModel,
                appName: appName ?? existing.appName,
                status: existing.status == "recording" ? "recorded" : existing.status,
                errorMessage: existing.errorMessage,
                groundTruthText: existing.groundTruthText,
                context: existing.context,
                accessibilitySnapshot: accessibilitySnapshot ?? existing.accessibilitySnapshot,
                visionImageFilePath: existing.visionImageFilePath,
                visionImageMimeType: existing.visionImageMimeType
            )
        } else {
            record = DebugCaptureRecord(
                id: id,
                runID: runID,
                createdAt: isoNow(),
                runDirectoryPath: runDir.path,
                promptsDirectoryPath: promptsDir.path,
                eventsFilePath: eventsPath.path,
                audioFilePath: audioPath.path,
                sampleRate: sampleRate,
                texts: DebugRunTexts(),
                metrics: DebugRunMetrics(),
                artifacts: DebugRunArtifactsSummary(
                    audioFile: "audio.wav",
                    eventsFile: "events.jsonl",
                    promptsDirectory: "prompts",
                    visionImageFile: nil,
                    visionImageMimeType: nil
                ),
                llmModel: llmModel,
                appName: appName,
                status: "skipped",
                accessibilitySnapshot: accessibilitySnapshot
            )
        }
        try writeRecord(record, to: manifestPath)
        return id
    }

    public func appendLog(captureID: String, log: DebugRunLog) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let record = try loadRecord(path: recordPath(captureID: captureID)) else { return }
        let encoder = JSONEncoder()
        let data = try encoder.encode(log)
        try appendLine(data: data, to: URL(fileURLWithPath: record.eventsFilePath))
    }

    public func updateResult(
        captureID: String,
        sttText: String?,
        outputText: String?,
        status: String,
        skipReason: String? = nil,
        failureStage: String? = nil,
        metrics: DebugRunMetrics? = nil,
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
        record.skipReason = skipReason
        record.failure = errorMessage.map { DebugRunFailure(stage: failureStage ?? "pipeline", message: $0) }
        record.texts = DebugRunTexts(stt: sttText, output: outputText)
        if let metrics {
            record.metrics = metrics
        } else {
            var updated = record.metrics
            updated.sttChars = sttText?.count ?? 0
            updated.outputChars = outputText?.count ?? 0
            record.metrics = updated
        }
        try writeRecord(record, to: path)
    }

    public func updateContext(captureID: String, context: ContextInfo?) throws {
        lock.lock()
        defer { lock.unlock() }

        let path = recordPath(captureID: captureID)
        guard var record = try loadRecord(path: path) else { return }
        record.context = context
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

        if let context {
            record.context = context
        }
        if let imageData, !imageData.isEmpty {
            let ext = imageExtension(for: imageMimeType)
            let imagePath = runDirectory(captureID: captureID).appendingPathComponent("vision.\(ext)", isDirectory: false)
            try imageData.write(to: imagePath, options: [.atomic])
            record.visionImageFilePath = imagePath.path
            record.visionImageMimeType = imageMimeType ?? (ext == "png" ? "image/png" : "image/jpeg")
            record.artifacts.visionImageFile = imagePath.lastPathComponent
            record.artifacts.visionImageMimeType = record.visionImageMimeType
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
