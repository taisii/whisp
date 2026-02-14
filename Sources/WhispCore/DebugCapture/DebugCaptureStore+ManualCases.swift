import Foundation

extension DebugCaptureStore {
    @discardableResult
    public func appendManualTestCase(captureID: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let record = try loadRecord(path: recordPath(captureID: captureID)) else {
            throw AppError.invalidArgument("capture not found: \(captureID)")
        }
        let datasetStore = BenchmarkDatasetStore()
        var existingRecords = try datasetStore.loadCases(path: manualCasesURL.path)
        if existingRecords.contains(where: { $0.id == record.id }) {
            throw AppError.invalidArgument("manual test case は既に追加済みです: \(record.id)")
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
        let payload = BenchmarkDatasetCaseRecord(
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
            appName: record.appName,
            context: normalizedContext(record.context),
            accessibility: mappedAccessibilitySnapshot(record.accessibilitySnapshot),
            visionImageFile: copiedVisionPath,
            visionImageMimeType: copiedVisionPath == nil ? nil : record.visionImageMimeType,
            labels: sttGroundTruth.isEmpty ? nil : BenchmarkDatasetLabels(transcriptGold: sttGroundTruth)
        )
        existingRecords.append(payload)
        try datasetStore.saveCases(path: manualCasesURL.path, records: existingRecords)
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

    private func mappedAccessibilitySnapshot(_ snapshot: AccessibilitySnapshot?) -> BenchmarkDatasetAccessibilitySnapshot? {
        guard let snapshot else { return nil }
        let focused = snapshot.focusedElement.map { element in
            BenchmarkDatasetAccessibilityFocusedElement(
                selectedText: element.selectedText,
                selectedRange: element.selectedRange.map {
                    BenchmarkDatasetAccessibilityTextRange(
                        location: $0.location,
                        length: $0.length
                    )
                },
                caretContext: element.caretContext,
                caretContextRange: element.caretContextRange.map {
                    BenchmarkDatasetAccessibilityTextRange(
                        location: $0.location,
                        length: $0.length
                    )
                }
            )
        }
        return BenchmarkDatasetAccessibilitySnapshot(focusedElement: focused)
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
