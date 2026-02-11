import CryptoKit
import Foundation

public final class BenchmarkStore: @unchecked Sendable {
    let lock = NSLock()
    let fileManager = FileManager.default
    let runsURL: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let paths = try? WhispPaths(environment: environment, allowTemporaryFallback: true)
        runsURL = paths?.benchmarkRunsDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("whisp-benchmark-runs", isDirectory: true)
    }

    public var runsDirectoryPath: String { runsURL.path }

    public func resolveRunPaths(runID: String) -> BenchmarkRunPaths {
        let runDir = runDirectory(runID: runID)
        return BenchmarkRunPaths(
            logDirectoryPath: "",
            rowsFilePath: "",
            summaryFilePath: "",
            casesFilePath: runDir.appendingPathComponent("cases.jsonl", isDirectory: false).path,
            eventsFilePath: runDir.appendingPathComponent("events.jsonl", isDirectory: false).path,
            artifactsDirectoryPath: runDir.appendingPathComponent("artifacts", isDirectory: true).path
        )
    }

    public func saveRun(_ run: BenchmarkRunRecord) throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectories()
        let runDir = runDirectory(runID: run.id)
        try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: artifactsDirectory(runID: run.id), withIntermediateDirectories: true)
        try ensureLogFileIfMissing(path: casesPath(runID: run.id))
        try ensureLogFileIfMissing(path: eventsPath(runID: run.id))

        let path = manifestPath(runID: run.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(run)
        try data.write(to: path, options: [.atomic])
    }

    public func loadRun(runID: String) throws -> BenchmarkRunRecord? {
        lock.lock()
        defer { lock.unlock() }
        return try loadRunWithoutLock(runID: runID)
    }

    public func listRuns(limit: Int = 100) throws -> [BenchmarkRunRecord] {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectories()
        let entries = try fileManager.contentsOfDirectory(at: runsURL, includingPropertiesForKeys: nil)
        var runs: [BenchmarkRunRecord] = []

        for entry in entries {
            let path = entry.appendingPathComponent("manifest.json", isDirectory: false)
            guard fileManager.fileExists(atPath: path.path) else { continue }
            guard let data = try? Data(contentsOf: path),
                  let run = try? JSONDecoder().decode(BenchmarkRunRecord.self, from: data)
            else {
                continue
            }
            runs.append(run)
        }

        let sorted = runs.sorted { $0.createdAt > $1.createdAt }
        return Array(sorted.prefix(max(1, limit)))
    }

    public func appendCaseResult(runID: String, result: BenchmarkCaseResult) throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureRunDirectories(runID: runID)
        let path = casesPath(runID: runID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let line = try encoder.encode(result)
        try appendLine(data: line, to: path)
    }

    public func loadCaseResults(runID: String) throws -> [BenchmarkCaseResult] {
        lock.lock()
        defer { lock.unlock() }

        let path = casesPath(runID: runID)
        guard fileManager.fileExists(atPath: path.path) else {
            return []
        }

        let text = try String(contentsOf: path, encoding: .utf8)
        let decoder = JSONDecoder()
        var rows: [BenchmarkCaseResult] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8) else {
                throw AppError.decode("invalid benchmark case row encoding")
            }
            rows.append(try decoder.decode(BenchmarkCaseResult.self, from: data))
        }
        return rows
    }

    public func appendEvent(runID: String, event: BenchmarkCaseEvent) throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureRunDirectories(runID: runID)
        let path = eventsPath(runID: runID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let line = try encoder.encode(event)
        try appendLine(data: line, to: path)
    }

    public func loadEvents(runID: String, caseID: String? = nil) throws -> [BenchmarkCaseEvent] {
        lock.lock()
        defer { lock.unlock() }

        let path = eventsPath(runID: runID)
        guard fileManager.fileExists(atPath: path.path) else {
            return []
        }

        let text = try String(contentsOf: path, encoding: .utf8)
        let decoder = JSONDecoder()
        var events: [BenchmarkCaseEvent] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8) else {
                throw AppError.decode("invalid benchmark event row encoding")
            }
            let event = try decoder.decode(BenchmarkCaseEvent.self, from: data)
            if let caseID, event.base.caseID != caseID {
                continue
            }
            events.append(event)
        }
        return events
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

        try ensureRunDirectories(runID: runID)

        let safeCase = sanitizePathComponent(caseID)
        let safeName = sanitizePathComponent(fileName)
        let token = timestampToken()
        let relative = "artifacts/\(safeCase)/\(token)-\(safeName)"
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

    func ensureDirectories() throws {
        try fileManager.createDirectory(at: runsURL, withIntermediateDirectories: true)
    }

    func ensureRunDirectories(runID: String) throws {
        try ensureDirectories()
        try fileManager.createDirectory(at: runDirectory(runID: runID), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: artifactsDirectory(runID: runID), withIntermediateDirectories: true)
        try ensureLogFileIfMissing(path: casesPath(runID: runID))
        try ensureLogFileIfMissing(path: eventsPath(runID: runID))
    }

    func runDirectory(runID: String) -> URL {
        runsURL.appendingPathComponent(runID, isDirectory: true)
    }

    func artifactsDirectory(runID: String) -> URL {
        runDirectory(runID: runID).appendingPathComponent("artifacts", isDirectory: true)
    }

    func manifestPath(runID: String) -> URL {
        runDirectory(runID: runID).appendingPathComponent("manifest.json", isDirectory: false)
    }

    func casesPath(runID: String) -> URL {
        runDirectory(runID: runID).appendingPathComponent("cases.jsonl", isDirectory: false)
    }

    func eventsPath(runID: String) -> URL {
        runDirectory(runID: runID).appendingPathComponent("events.jsonl", isDirectory: false)
    }

    func loadRunWithoutLock(runID: String) throws -> BenchmarkRunRecord? {
        let path = manifestPath(runID: runID)
        guard fileManager.fileExists(atPath: path.path) else {
            return nil
        }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(BenchmarkRunRecord.self, from: data)
    }

    func appendLine(data: Data, to path: URL) throws {
        guard let handle = try? FileHandle(forWritingTo: path) else {
            throw AppError.io("benchmark log file open failed: \(path.path)")
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    func ensureLogFileIfMissing(path: URL) throws {
        if fileManager.fileExists(atPath: path.path) {
            return
        }
        try Data().write(to: path, options: [.atomic])
    }

    func sanitizePathComponent(_ value: String) -> String {
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

    func timestampToken() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}
