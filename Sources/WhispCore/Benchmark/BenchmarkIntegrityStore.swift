import Foundation

public final class BenchmarkIntegrityStore: @unchecked Sendable {
    struct ExclusionState: Codable {
        var issueIDs: [String]
    }

    let lock = NSLock()
    let fileManager = FileManager.default
    let directoryURL: URL
    let exclusionsURL: URL
    let autoScanStateURL: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let paths = try? WhispPaths(environment: environment, allowTemporaryFallback: true)
        directoryURL = paths?.benchmarkDirectory
            .appendingPathComponent("integrity", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("whisp-benchmark-integrity", isDirectory: true)
        exclusionsURL = directoryURL.appendingPathComponent("exclusions.json", isDirectory: false)
        autoScanStateURL = directoryURL.appendingPathComponent("auto_scan_state.json", isDirectory: false)
    }

    public var integrityDirectoryPath: String { directoryURL.path }

    public func issuesFilePath(task: BenchmarkKind) -> String {
        issuesURL(task: task).path
    }

    public func loadIssues(task: BenchmarkKind) throws -> [BenchmarkIntegrityIssue] {
        lock.lock()
        defer { lock.unlock() }

        let exclusions = try loadExclusionsWithoutLock()
        let issues = try loadIssuesWithoutLock(task: task).map { issue -> BenchmarkIntegrityIssue in
            var updated = issue
            updated.excluded = updated.excluded || exclusions.contains(updated.id)
            return updated
        }
        return issues.sorted {
            if $0.excluded != $1.excluded {
                return !$0.excluded && $1.excluded
            }
            if $0.caseID != $1.caseID {
                return $0.caseID < $1.caseID
            }
            return $0.issueType < $1.issueType
        }
    }

    public func saveIssues(task: BenchmarkKind, issues: [BenchmarkIntegrityIssue]) throws {
        lock.lock()
        defer { lock.unlock() }

        var exclusions = try loadExclusionsWithoutLock()
        for issue in issues {
            if issue.excluded {
                exclusions.insert(issue.id)
            }
        }

        let normalized = issues.map { issue -> BenchmarkIntegrityIssue in
            var copied = issue
            copied.excluded = copied.excluded || exclusions.contains(issue.id)
            return copied
        }

        try saveExclusionsWithoutLock(exclusions)
        try saveIssuesWithoutLock(task: task, issues: normalized)
    }

    public func setExcluded(issueID: String, task: BenchmarkKind, excluded: Bool) throws {
        lock.lock()
        defer { lock.unlock() }

        var exclusions = try loadExclusionsWithoutLock()
        if excluded {
            exclusions.insert(issueID)
        } else {
            exclusions.remove(issueID)
        }
        try saveExclusionsWithoutLock(exclusions)

        var issues = try loadIssuesWithoutLock(task: task)
        if let index = issues.firstIndex(where: { $0.id == issueID }) {
            issues[index].excluded = excluded
            try saveIssuesWithoutLock(task: task, issues: issues)
        }
    }

    public func loadAutoScanState() throws -> BenchmarkIntegrityAutoScanState? {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectoryExists()
        guard fileManager.fileExists(atPath: autoScanStateURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: autoScanStateURL)
        if data.isEmpty {
            return nil
        }
        do {
            return try JSONDecoder().decode(BenchmarkIntegrityAutoScanState.self, from: data)
        } catch {
            throw AppError.decode("failed to decode auto_scan_state.json: \(error.localizedDescription)")
        }
    }

    public func saveAutoScanState(_ state: BenchmarkIntegrityAutoScanState) throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: autoScanStateURL, options: [.atomic])
    }

    public func clearAutoScanState() throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectoryExists()
        if fileManager.fileExists(atPath: autoScanStateURL.path) {
            try fileManager.removeItem(at: autoScanStateURL)
        }
    }

    func issuesURL(task: BenchmarkKind) -> URL {
        directoryURL.appendingPathComponent("issues_\(task.rawValue).json", isDirectory: false)
    }

    func ensureDirectoryExists() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: exclusionsURL.path) {
            let data = try JSONEncoder().encode(ExclusionState(issueIDs: []))
            try data.write(to: exclusionsURL, options: [.atomic])
        }
    }

    func loadIssuesWithoutLock(task: BenchmarkKind) throws -> [BenchmarkIntegrityIssue] {
        try ensureDirectoryExists()
        let url = issuesURL(task: task)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return []
        }
        do {
            return try JSONDecoder().decode([BenchmarkIntegrityIssue].self, from: data)
        } catch {
            throw AppError.decode("failed to decode integrity issues: \(error.localizedDescription)")
        }
    }

    func saveIssuesWithoutLock(task: BenchmarkKind, issues: [BenchmarkIntegrityIssue]) throws {
        try ensureDirectoryExists()
        let url = issuesURL(task: task)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(issues)
        try data.write(to: url, options: [.atomic])
    }

    func loadExclusionsWithoutLock() throws -> Set<String> {
        try ensureDirectoryExists()
        guard fileManager.fileExists(atPath: exclusionsURL.path) else {
            return []
        }
        let data = try Data(contentsOf: exclusionsURL)
        if data.isEmpty {
            return []
        }
        do {
            let decoded = try JSONDecoder().decode(ExclusionState.self, from: data)
            return Set(decoded.issueIDs)
        } catch {
            throw AppError.decode("failed to decode exclusions.json: \(error.localizedDescription)")
        }
    }

    func saveExclusionsWithoutLock(_ exclusions: Set<String>) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let state = ExclusionState(issueIDs: exclusions.sorted())
        let data = try encoder.encode(state)
        try data.write(to: exclusionsURL, options: [.atomic])
    }
}
