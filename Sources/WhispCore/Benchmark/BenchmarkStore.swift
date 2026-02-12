import CryptoKit
import Foundation

public final class BenchmarkStore: @unchecked Sendable {
    let lock = NSLock()
    let fileManager = FileManager.default
    let runsURL: URL

    private let schemaMarkerFile = ".schema-v7"

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let paths = try? WhispPaths(environment: environment, allowTemporaryFallback: true)
        runsURL = paths?.benchmarkRunsDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("whisp-benchmark-runs", isDirectory: true)
    }

    public var runsDirectoryPath: String { runsURL.path }

    public func runDirectoryPath(runID: String) -> String {
        runDirectory(runID: runID).path
    }

    public func resolveRunPaths(runID: String) -> BenchmarkRunPaths {
        let runDir = runDirectory(runID: runID)
        return BenchmarkRunPaths(
            manifestPath: runDir.appendingPathComponent("manifest.json", isDirectory: false).path,
            orchestratorEventsPath: runDir.appendingPathComponent("orchestrator_events.jsonl", isDirectory: false).path,
            casesIndexPath: runDir.appendingPathComponent("cases_index.jsonl", isDirectory: false).path,
            casesDirectoryPath: runDir.appendingPathComponent("cases", isDirectory: true).path
        )
    }

    public func resolveCasePaths(runID: String, caseID: String) -> BenchmarkCasePaths {
        let caseDir = caseDirectory(runID: runID, caseID: caseID)
        return BenchmarkCasePaths(
            caseDirectoryPath: caseDir.path,
            manifestPath: caseDir.appendingPathComponent("manifest.json", isDirectory: false).path,
            metricsPath: caseDir.appendingPathComponent("metrics.json", isDirectory: false).path,
            eventsPath: caseDir.appendingPathComponent("events.jsonl", isDirectory: false).path,
            ioDirectoryPath: caseDir.appendingPathComponent("io", isDirectory: true).path,
            artifactsDirectoryPath: caseDir.appendingPathComponent("artifacts", isDirectory: true).path
        )
    }

    public func saveRun(_ run: BenchmarkRunRecord) throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureRunDirectoriesLocked(runID: run.id)
        let path = manifestPath(runID: run.id)
        try writePrettyJSON(run, to: path)
    }

    public func loadRun(runID: String) throws -> BenchmarkRunRecord? {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectoriesLocked()
        let path = manifestPath(runID: runID)
        guard fileManager.fileExists(atPath: path.path) else {
            return nil
        }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(BenchmarkRunRecord.self, from: data)
    }

    public func listRuns(limit: Int = 100) throws -> [BenchmarkRunRecord] {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectoriesLocked()
        let entries = try fileManager.contentsOfDirectory(at: runsURL, includingPropertiesForKeys: nil)
        var runs: [BenchmarkRunRecord] = []

        for entry in entries {
            guard isRunDirectory(entry) else { continue }
            let path = entry.appendingPathComponent("manifest.json", isDirectory: false)
            guard fileManager.fileExists(atPath: path.path) else { continue }
            guard let data = try? Data(contentsOf: path),
                  let run = try? JSONDecoder().decode(BenchmarkRunRecord.self, from: data)
            else {
                continue
            }
            guard run.schemaVersion == 7 else { continue }
            runs.append(run)
        }

        let sorted = runs.sorted { $0.createdAt > $1.createdAt }
        return Array(sorted.prefix(max(1, limit)))
    }

    public func findLatestCompletedRun(matching key: BenchmarkKey) throws -> BenchmarkRunRecord? {
        let runs = try listRuns(limit: 2_000)
        return runs
            .filter { $0.status == .completed && $0.benchmarkKey == key }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    public func appendCaseResult(runID: String, result: BenchmarkCaseResult) throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureCaseDirectoriesLocked(runID: runID, caseID: result.id)

        let casesIndex = casesIndexPath(runID: runID)
        try appendJSONL(result, to: casesIndex)

        let now = isoNow()
        let manifest = BenchmarkCaseManifest(
            runID: runID,
            caseID: result.id,
            status: result.status,
            reason: result.reason,
            startedAt: now,
            endedAt: now,
            audioFilePath: nil,
            contextUsed: result.contextUsed ?? false,
            visionImageAttached: result.visionImageAttached ?? false,
            transcriptSource: result.sources.transcript,
            inputSource: result.sources.input,
            referenceSource: result.sources.reference
        )
        try writePrettyJSON(manifest, to: caseManifestPath(runID: runID, caseID: result.id))
        try writePrettyJSON(result.metrics, to: caseMetricsPath(runID: runID, caseID: result.id))
    }

    public func loadCaseResults(runID: String) throws -> [BenchmarkCaseResult] {
        lock.lock()
        defer { lock.unlock() }

        let path = casesIndexPath(runID: runID)
        guard fileManager.fileExists(atPath: path.path) else {
            return []
        }

        let rows: [BenchmarkCaseResult] = try loadJSONL(path: path)
        var latestByID: [String: BenchmarkCaseResult] = [:]
        var order: [String] = []

        for row in rows {
            if latestByID[row.id] == nil {
                order.append(row.id)
            }
            latestByID[row.id] = row
        }

        return order.compactMap { latestByID[$0] }
    }

    public func saveCaseManifest(runID: String, manifest: BenchmarkCaseManifest) throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureCaseDirectoriesLocked(runID: runID, caseID: manifest.caseID)
        try writePrettyJSON(manifest, to: caseManifestPath(runID: runID, caseID: manifest.caseID))
    }

    public func loadCaseManifest(runID: String, caseID: String) throws -> BenchmarkCaseManifest? {
        lock.lock()
        defer { lock.unlock() }

        let path = caseManifestPath(runID: runID, caseID: caseID)
        guard fileManager.fileExists(atPath: path.path) else {
            return nil
        }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(BenchmarkCaseManifest.self, from: data)
    }

    public func saveCaseMetrics(runID: String, caseID: String, metrics: BenchmarkCaseMetrics) throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureCaseDirectoriesLocked(runID: runID, caseID: caseID)
        try writePrettyJSON(metrics, to: caseMetricsPath(runID: runID, caseID: caseID))
    }

    public func loadCaseMetrics(runID: String, caseID: String) throws -> BenchmarkCaseMetrics? {
        lock.lock()
        defer { lock.unlock() }

        let path = caseMetricsPath(runID: runID, caseID: caseID)
        guard fileManager.fileExists(atPath: path.path) else {
            return nil
        }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(BenchmarkCaseMetrics.self, from: data)
    }

    public func appendEvent(runID: String, event: BenchmarkCaseEvent) throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureCaseDirectoriesLocked(runID: runID, caseID: event.base.caseID)
        let path = caseEventsPath(runID: runID, caseID: event.base.caseID)
        try appendJSONL(event, to: path)
        try applyCaseEventSideEffectsLocked(runID: runID, event: event)
    }

    public func loadEvents(runID: String, caseID: String? = nil) throws -> [BenchmarkCaseEvent] {
        lock.lock()
        defer { lock.unlock() }

        if let caseID {
            let path = caseEventsPath(runID: runID, caseID: caseID)
            guard fileManager.fileExists(atPath: path.path) else {
                return []
            }
            let events: [BenchmarkCaseEvent] = try loadJSONL(path: path)
            return events.sorted(by: { lhs, rhs in
                if lhs.base.startedAtMs != rhs.base.startedAtMs {
                    return lhs.base.startedAtMs < rhs.base.startedAtMs
                }
                return lhs.base.recordedAtMs < rhs.base.recordedAtMs
            })
        }

        let casesDir = casesDirectory(runID: runID)
        guard fileManager.fileExists(atPath: casesDir.path) else {
            return []
        }
        let caseEntries = try fileManager.contentsOfDirectory(at: casesDir, includingPropertiesForKeys: nil)
        var allEvents: [BenchmarkCaseEvent] = []
        for entry in caseEntries where isRunDirectory(entry) {
            let path = entry.appendingPathComponent("events.jsonl", isDirectory: false)
            guard fileManager.fileExists(atPath: path.path) else { continue }
            let events: [BenchmarkCaseEvent] = try loadJSONL(path: path)
            allEvents.append(contentsOf: events)
        }
        return allEvents.sorted(by: { lhs, rhs in
            if lhs.base.startedAtMs != rhs.base.startedAtMs {
                return lhs.base.startedAtMs < rhs.base.startedAtMs
            }
            return lhs.base.recordedAtMs < rhs.base.recordedAtMs
        })
    }

    public func appendOrchestratorEvent(runID: String, event: BenchmarkOrchestratorEvent) throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureRunDirectoriesLocked(runID: runID)
        try appendJSONL(event, to: orchestratorEventsPath(runID: runID))
    }

    public func loadOrchestratorEvents(runID: String) throws -> [BenchmarkOrchestratorEvent] {
        lock.lock()
        defer { lock.unlock() }

        let path = orchestratorEventsPath(runID: runID)
        guard fileManager.fileExists(atPath: path.path) else {
            return []
        }
        let events: [BenchmarkOrchestratorEvent] = try loadJSONL(path: path)
        return events.sorted { $0.recordedAtMs < $1.recordedAtMs }
    }

    public func writeCaseIOText(runID: String, caseID: String, fileName: String, text: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        try ensureCaseDirectoriesLocked(runID: runID, caseID: caseID)
        let safe = sanitizePathComponent(fileName)
        let path = caseIODirectory(runID: runID, caseID: caseID)
            .appendingPathComponent(safe, isDirectory: false)
        try text.data(using: .utf8)?.write(to: path, options: [.atomic])
        return path.path
    }

    public func writeArtifact(
        runID: String,
        caseID: String,
        fileName: String,
        mimeType: String,
        data: Data,
        maskRuleID: String? = nil
    ) throws -> BenchmarkArtifactRef {
        lock.lock()
        defer { lock.unlock() }

        try ensureCaseDirectoriesLocked(runID: runID, caseID: caseID)

        let safeCase = sanitizePathComponent(caseID)
        let safeName = sanitizePathComponent(fileName)
        let token = timestampToken()
        let relative = "cases/\(safeCase)/artifacts/\(token)-\(safeName)"
        let url = runDirectory(runID: runID).appendingPathComponent(relative, isDirectory: false)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])

        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return BenchmarkArtifactRef(
            relativePath: relative,
            mimeType: mimeType,
            sha256: sha,
            bytes: data.count,
            maskRuleID: maskRuleID
        )
    }

    public func loadArtifactData(runID: String, ref: BenchmarkArtifactRef) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        let url = runDirectory(runID: runID).appendingPathComponent(ref.relativePath, isDirectory: false)
        return try Data(contentsOf: url)
    }

    public func loadArtifactText(runID: String, ref: BenchmarkArtifactRef) throws -> String {
        let data = try loadArtifactData(runID: runID, ref: ref)
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func deleteRun(runID: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let runDir = runDirectory(runID: runID)
        guard fileManager.fileExists(atPath: runDir.path) else {
            return
        }
        try fileManager.removeItem(at: runDir)
    }

    private func ensureDirectoriesLocked() throws {
        try fileManager.createDirectory(at: runsURL, withIntermediateDirectories: true)
        try prepareSchemaLayoutLocked()
    }

    private func prepareSchemaLayoutLocked() throws {
        let marker = runsURL.appendingPathComponent(schemaMarkerFile, isDirectory: false)
        if fileManager.fileExists(atPath: marker.path) {
            return
        }
        try Data("7\n".utf8).write(to: marker, options: [.atomic])
    }

    private func ensureRunDirectoriesLocked(runID: String) throws {
        try ensureDirectoriesLocked()
        let runDir = runDirectory(runID: runID)
        try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: casesDirectory(runID: runID), withIntermediateDirectories: true)
        try ensureLogFileIfMissing(path: casesIndexPath(runID: runID))
        try ensureLogFileIfMissing(path: orchestratorEventsPath(runID: runID))
    }

    private func ensureCaseDirectoriesLocked(runID: String, caseID: String) throws {
        try ensureRunDirectoriesLocked(runID: runID)
        let caseDir = caseDirectory(runID: runID, caseID: caseID)
        try fileManager.createDirectory(at: caseDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: caseIODirectory(runID: runID, caseID: caseID), withIntermediateDirectories: true)
        try ensureLogFileIfMissing(path: caseEventsPath(runID: runID, caseID: caseID))
    }

    private func runDirectory(runID: String) -> URL {
        runsURL.appendingPathComponent(runID, isDirectory: true)
    }

    private func manifestPath(runID: String) -> URL {
        runDirectory(runID: runID).appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func orchestratorEventsPath(runID: String) -> URL {
        runDirectory(runID: runID).appendingPathComponent("orchestrator_events.jsonl", isDirectory: false)
    }

    private func casesIndexPath(runID: String) -> URL {
        runDirectory(runID: runID).appendingPathComponent("cases_index.jsonl", isDirectory: false)
    }

    private func casesDirectory(runID: String) -> URL {
        runDirectory(runID: runID).appendingPathComponent("cases", isDirectory: true)
    }

    private func caseDirectory(runID: String, caseID: String) -> URL {
        casesDirectory(runID: runID).appendingPathComponent(sanitizePathComponent(caseID), isDirectory: true)
    }

    private func caseManifestPath(runID: String, caseID: String) -> URL {
        caseDirectory(runID: runID, caseID: caseID).appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func caseMetricsPath(runID: String, caseID: String) -> URL {
        caseDirectory(runID: runID, caseID: caseID).appendingPathComponent("metrics.json", isDirectory: false)
    }

    private func caseEventsPath(runID: String, caseID: String) -> URL {
        caseDirectory(runID: runID, caseID: caseID).appendingPathComponent("events.jsonl", isDirectory: false)
    }

    private func caseIODirectory(runID: String, caseID: String) -> URL {
        caseDirectory(runID: runID, caseID: caseID).appendingPathComponent("io", isDirectory: true)
    }

    private func caseArtifactsDirectory(runID: String, caseID: String) -> URL {
        caseDirectory(runID: runID, caseID: caseID).appendingPathComponent("artifacts", isDirectory: true)
    }

    private func appendJSONL<T: Encodable>(_ value: T, to path: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let line = try encoder.encode(value)
        try appendLine(data: line, to: path)
    }

    private func applyCaseEventSideEffectsLocked(runID: String, event: BenchmarkCaseEvent) throws {
        switch event {
        case let .error(log):
            let errorPath = caseArtifactsDirectory(runID: runID, caseID: log.base.caseID)
                .appendingPathComponent("error.json", isDirectory: false)
            try fileManager.createDirectory(at: errorPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload = ErrorArtifactPayload(
                runID: runID,
                caseID: log.base.caseID,
                errorType: log.errorType ?? "",
                originStage: log.originStage?.rawValue ?? "",
                message: log.message,
                recordedAtMs: log.base.recordedAtMs
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: errorPath, options: [.atomic])
        default:
            break
        }
    }

    private func loadJSONL<T: Decodable>(path: URL) throws -> [T] {
        let text = try String(contentsOf: path, encoding: .utf8)
        let decoder = JSONDecoder()
        var rows: [T] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8) else {
                throw AppError.decode("invalid benchmark row encoding")
            }
            rows.append(try decoder.decode(T.self, from: data))
        }
        return rows
    }

    private func writePrettyJSON<T: Encodable>(_ value: T, to path: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: path, options: [.atomic])
    }

    private func appendLine(data: Data, to path: URL) throws {
        guard let handle = try? FileHandle(forWritingTo: path) else {
            throw AppError.io("benchmark log file open failed: \(path.path)")
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    private func ensureLogFileIfMissing(path: URL) throws {
        if fileManager.fileExists(atPath: path.path) {
            return
        }
        try Data().write(to: path, options: [.atomic])
    }

    private func isRunDirectory(_ url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix(".") {
            return false
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    private func sanitizePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let transformed = value.unicodeScalars.map { scalar -> String in
            if allowed.contains(scalar) {
                return String(scalar)
            }
            return "_"
        }.joined()
        let trimmed = transformed.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return trimmed.isEmpty ? "item" : trimmed
    }

    private func timestampToken() -> String {
        WhispTime.timestampTokenWithMillis()
    }

    private func isoNow() -> String {
        WhispTime.isoNow()
    }
}

private struct ErrorArtifactPayload: Codable {
    let runID: String
    let caseID: String
    let errorType: String
    let originStage: String
    let message: String
    let recordedAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case caseID = "case_id"
        case errorType = "error_type"
        case originStage = "origin_stage"
        case message
        case recordedAtMs = "recorded_at_ms"
    }
}
