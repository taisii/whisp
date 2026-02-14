import Foundation

public struct BenchmarkCandidateCount: Codable, Equatable, Sendable {
    public let task: String
    public let count: Int

    public init(task: String, count: Int) {
        self.task = task
        self.count = count
    }
}

public struct BenchmarkLatestRun: Codable, Equatable, Sendable {
    public let task: String
    public let runID: String
    public let createdAt: String
    public let status: String

    public init(task: String, runID: String, createdAt: String, status: String) {
        self.task = task
        self.runID = runID
        self.createdAt = createdAt
        self.status = status
    }
}

public struct BenchmarkStatusSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let candidateCounts: [BenchmarkCandidateCount]
    public let latestRuns: [BenchmarkLatestRun]

    public init(
        generatedAt: String,
        candidateCounts: [BenchmarkCandidateCount],
        latestRuns: [BenchmarkLatestRun]
    ) {
        self.generatedAt = generatedAt
        self.candidateCounts = candidateCounts
        self.latestRuns = latestRuns
    }
}

public struct BenchmarkIssueCount: Codable, Equatable, Sendable {
    public let severity: String
    public let count: Int

    public init(severity: String, count: Int) {
        self.severity = severity
        self.count = count
    }
}

public struct BenchmarkIntegritySnapshot: Codable, Equatable, Sendable {
    public let task: String
    public let totalIssues: Int
    public let severityCounts: [BenchmarkIssueCount]

    public init(task: String, totalIssues: Int, severityCounts: [BenchmarkIssueCount]) {
        self.task = task
        self.totalIssues = totalIssues
        self.severityCounts = severityCounts
    }
}

public final class BenchmarkDiagnosticsService: @unchecked Sendable {
    private let candidateStore: BenchmarkCandidateStore
    private let benchmarkStore: BenchmarkStore
    private let integrityStore: BenchmarkIntegrityStore
    private let datasetStore: BenchmarkDatasetStore
    private let environment: [String: String]

    public init(
        candidateStore: BenchmarkCandidateStore = BenchmarkCandidateStore(),
        benchmarkStore: BenchmarkStore = BenchmarkStore(),
        integrityStore: BenchmarkIntegrityStore = BenchmarkIntegrityStore(),
        datasetStore: BenchmarkDatasetStore = BenchmarkDatasetStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.candidateStore = candidateStore
        self.benchmarkStore = benchmarkStore
        self.integrityStore = integrityStore
        self.datasetStore = datasetStore
        self.environment = environment
    }

    public func defaultCasesPath() -> String {
        if let paths = try? WhispPaths(environment: environment, allowTemporaryFallback: true) {
            return paths.manualCasesFile.path
        }

        let home = (environment["HOME"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("whisp", isDirectory: true)
                .appendingPathComponent("debug", isDirectory: true)
                .appendingPathComponent("manual_test_cases.jsonl", isDirectory: false)
                .path
        }

        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("manual_test_cases.jsonl", isDirectory: false)
            .path
    }

    public func loadStatusSnapshot() throws -> BenchmarkStatusSnapshot {
        let candidates = try candidateStore.listCandidates()
        let candidateCounts = BenchmarkKind.allCases
            .map { task in
                BenchmarkCandidateCount(
                    task: task.rawValue,
                    count: candidates.filter { $0.task == task }.count
                )
            }
            .sorted { $0.task < $1.task }

        // benchmark-status は task ごとの最新 run を表示するため、全 run を対象に判定する。
        let runs = try benchmarkStore.listRuns(limit: Int.max)
        var latestByTask: [BenchmarkKind: BenchmarkRunRecord] = [:]
        for run in runs {
            guard latestByTask[run.kind] == nil else {
                continue
            }
            latestByTask[run.kind] = run
        }

        let latestRuns = BenchmarkKind.allCases.compactMap { task -> BenchmarkLatestRun? in
            guard let run = latestByTask[task] else {
                return nil
            }
            return BenchmarkLatestRun(
                task: task.rawValue,
                runID: run.id,
                createdAt: run.createdAt,
                status: run.status.rawValue
            )
        }

        return BenchmarkStatusSnapshot(
            generatedAt: Self.isoNow(),
            candidateCounts: candidateCounts,
            latestRuns: latestRuns.sorted { $0.task < $1.task }
        )
    }

    public func loadIntegritySnapshot(task: BenchmarkKind, casesPath: String) throws -> BenchmarkIntegritySnapshot {
        guard task == .stt || task == .generation else {
            throw AppError.invalidArgument("integrity diagnostics supports only stt/generation")
        }

        let normalizedCasesPath = WhispPaths.normalizeForStorage(casesPath)
        let records = try datasetStore.loadCases(path: normalizedCasesPath)
        let scanCases = records.map { item in
            BenchmarkIntegrityScanCase(
                id: item.id,
                audioFile: item.audioFile,
                sttText: item.sttText,
                groundTruthText: item.groundTruthText,
                transcriptGold: item.labels?.transcriptGold,
                transcriptSilver: item.labels?.transcriptSilver
            )
        }

        let scannedIssues = BenchmarkIntegrityScanner.scanIssues(
            task: task,
            cases: scanCases,
            sourcePath: normalizedCasesPath,
            detectedAt: Self.isoNow()
        )

        let excludedIDs = Set(try integrityStore
            .loadIssues(task: task)
            .filter(\.excluded)
            .map(\.id))

        let activeIssues = scannedIssues.filter { !excludedIDs.contains($0.id) }
        let countsBySeverity = Dictionary(grouping: activeIssues, by: { Self.severity(for: $0.issueType) })
            .map { key, value in
                BenchmarkIssueCount(severity: key, count: value.count)
            }
            .sorted { $0.severity < $1.severity }

        return BenchmarkIntegritySnapshot(
            task: task.rawValue,
            totalIssues: activeIssues.count,
            severityCounts: countsBySeverity
        )
    }

    private static func severity(for issueType: String) -> String {
        switch issueType {
        case "missing_audio_file":
            return "high"
        case "missing_stt_text", "missing_reference":
            return "medium"
        default:
            return "low"
        }
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
