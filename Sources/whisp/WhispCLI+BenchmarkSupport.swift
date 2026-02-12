import Foundation
import CryptoKit
import WhispCore

final class BenchmarkRunRecorder: @unchecked Sendable {
    private let store: BenchmarkStore
    private var run: BenchmarkRunRecord

    init(
        runID: String,
        kind: BenchmarkKind,
        options: BenchmarkRunOptions,
        candidateID: String? = nil,
        benchmarkKey: BenchmarkKey? = nil,
        initialMetrics: BenchmarkRunMetrics? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        self.store = BenchmarkStore(environment: environment)
        self.run = BenchmarkRunRecord(
            id: runID,
            kind: kind,
            status: .running,
            createdAt: WhispCLI.isoNow(),
            updatedAt: WhispCLI.isoNow(),
            options: options,
            candidateID: candidateID ?? options.candidateID,
            benchmarkKey: benchmarkKey,
            metrics: initialMetrics ?? BenchmarkRunMetrics(
                casesTotal: 0,
                casesSelected: 0,
                executedCases: 0,
                skippedCases: 0,
                failedCases: 0
            ),
            paths: store.resolveRunPaths(runID: runID)
        )
        try store.saveRun(run)
        try store.appendOrchestratorEvent(
            runID: runID,
            event: BenchmarkOrchestratorEvent(
                runID: runID,
                stage: .runStart,
                status: .ok,
                recordedAtMs: WhispCLI.nowEpochMs()
            )
        )
    }

    var runID: String { run.id }

    func appendCaseResult(_ result: BenchmarkCaseResult) throws {
        try store.appendCaseResult(runID: run.id, result: result)
        try store.appendOrchestratorEvent(
            runID: run.id,
            event: BenchmarkOrchestratorEvent(
                runID: run.id,
                caseID: result.id,
                stage: result.status == .error ? .caseFailed : .caseFinished,
                status: WhispCLI.eventStatus(from: result.status),
                recordedAtMs: WhispCLI.nowEpochMs(),
                attrs: [
                    "case_status": result.status.rawValue,
                    "reason": result.reason ?? "",
                ]
            )
        )
    }

    func appendEvent(_ event: BenchmarkCaseEvent) throws {
        try store.appendEvent(runID: run.id, event: event)
    }

    func appendEvents(_ events: [BenchmarkCaseEvent]) throws {
        for event in events.sorted(by: { $0.base.startedAtMs < $1.base.startedAtMs }) {
            try appendEvent(event)
        }
    }

    func markCaseQueued(caseID: String) throws {
        try store.appendOrchestratorEvent(
            runID: run.id,
            event: BenchmarkOrchestratorEvent(
                runID: run.id,
                caseID: caseID,
                stage: .caseQueued,
                status: .ok,
                recordedAtMs: WhispCLI.nowEpochMs()
            )
        )
    }

    func markCaseStarted(caseID: String) throws {
        try store.appendOrchestratorEvent(
            runID: run.id,
            event: BenchmarkOrchestratorEvent(
                runID: run.id,
                caseID: caseID,
                stage: .caseStarted,
                status: .ok,
                recordedAtMs: WhispCLI.nowEpochMs()
            )
        )
    }

    func saveCaseManifest(_ manifest: BenchmarkCaseManifest) throws {
        try store.saveCaseManifest(runID: run.id, manifest: manifest)
    }

    func saveCaseMetrics(caseID: String, metrics: BenchmarkCaseMetrics) throws {
        try store.saveCaseMetrics(runID: run.id, caseID: caseID, metrics: metrics)
    }

    @discardableResult
    func writeCaseIOText(caseID: String, fileName: String, text: String) throws -> String {
        try store.writeCaseIOText(runID: run.id, caseID: caseID, fileName: fileName, text: text)
    }

    @discardableResult
    func finalize(
        metrics: BenchmarkRunMetrics,
        options: BenchmarkRunOptions? = nil,
        status: BenchmarkRunStatus = .completed
    ) throws -> BenchmarkRunRecord {
        run.metrics = metrics
        if let options {
            run.options = options
        }
        run.status = status
        run.updatedAt = WhispCLI.isoNow()
        try store.saveRun(run)
        try store.appendOrchestratorEvent(
            runID: run.id,
            event: BenchmarkOrchestratorEvent(
                runID: run.id,
                stage: status == .completed ? .runCompleted : .runFailed,
                status: status == .completed ? .ok : .error,
                recordedAtMs: WhispCLI.nowEpochMs(),
                attrs: [
                    "cases_selected": String(metrics.casesSelected),
                    "executed_cases": String(metrics.executedCases),
                    "skipped_cases": String(metrics.skippedCases),
                    "failed_cases": String(metrics.failedCases),
                ]
            )
        )
        return run
    }
}

extension WhispCLI {
    actor BenchmarkCaseWorkQueue {
        private let items: [ManualBenchmarkCase]
        private var nextIndex = 0

        init(items: [ManualBenchmarkCase]) {
            self.items = items
        }

        func pop() -> (index: Int, item: ManualBenchmarkCase)? {
            guard nextIndex < items.count else {
                return nil
            }
            defer { nextIndex += 1 }
            return (nextIndex, items[nextIndex])
        }
    }

    static func loadManualBenchmarkCases(path: String) throws -> [ManualBenchmarkCase] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidArgument("manual test case path が空です")
        }
        guard FileManager.default.fileExists(atPath: trimmed) else {
            throw AppError.invalidArgument("manual test case file が見つかりません: \(trimmed)")
        }

        let content = try String(contentsOfFile: trimmed, encoding: .utf8)
        var results: [ManualBenchmarkCase] = []
        let decoder = JSONDecoder()

        for (index, rawLine) in content.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            guard let data = line.data(using: .utf8) else {
                throw AppError.invalidArgument("JSONLの読み込みに失敗しました(line=\(index + 1))")
            }
            do {
                let item = try decoder.decode(ManualBenchmarkCase.self, from: data)
                results.append(item)
            } catch {
                throw AppError.invalidArgument("JSONLのデコードに失敗しました(line=\(index + 1)): \(error.localizedDescription)")
            }
        }
        return results
    }

    static func benchmarkTimestampToken() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    static func defaultBenchmarkRunID(kind: BenchmarkKind) -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "\(kind.rawValue)-\(benchmarkTimestampToken())-\(suffix)"
    }

    static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    static func toBenchmarkLatencyDistribution(_ source: LatencyDistributionLog?) -> BenchmarkLatencyDistribution? {
        guard let source else { return nil }
        return BenchmarkLatencyDistribution(
            avg: source.avg,
            p50: source.p50,
            p95: source.p95,
            p99: source.p99
        )
    }

    static func eventStatus(from caseStatus: BenchmarkCaseStatus) -> BenchmarkEventStatus {
        switch caseStatus {
        case .ok:
            return .ok
        case .skipped:
            return .skipped
        case .error:
            return .error
        }
    }

    static func nowEpochMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    static func defaultBenchmarkWorkers() -> Int {
        max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
    }

    static func resolveBenchmarkWorkers(_ requested: Int?) -> Int {
        guard let requested else {
            return defaultBenchmarkWorkers()
        }
        return max(1, min(32, requested))
    }

    static func runBenchmarkCaseWorkers<Result: Sendable>(
        cases: [ManualBenchmarkCase],
        workers requestedWorkers: Int?,
        operation: @escaping @Sendable (_ index: Int, _ item: ManualBenchmarkCase) async throws -> Result
    ) async throws -> [Result] {
        let workers = resolveBenchmarkWorkers(requestedWorkers)
        guard !cases.isEmpty else { return [] }
        let queue = BenchmarkCaseWorkQueue(items: cases)

        return try await withThrowingTaskGroup(of: [(Int, Result)].self, returning: [Result].self) { group in
            for _ in 0..<workers {
                group.addTask {
                    var bucket: [(Int, Result)] = []
                    while let payload = await queue.pop() {
                        bucket.append((payload.index, try await operation(payload.index, payload.item)))
                    }
                    return bucket
                }
            }

            var rows: [(Int, Result)] = []
            for try await chunk in group {
                rows.append(contentsOf: chunk)
            }
            rows.sort { $0.0 < $1.0 }
            return rows.map(\.1)
        }
    }

    static func makeEventBase(
        runID: String,
        caseID: String,
        stage: BenchmarkEventStage,
        status: BenchmarkEventStatus,
        startedAtMs: Int64? = nil,
        endedAtMs: Int64? = nil
    ) -> BenchmarkCaseEventBase {
        let measuredEnd = endedAtMs ?? nowEpochMs()
        let measuredStart = startedAtMs ?? max(Int64(0), measuredEnd - 1)
        let start = min(measuredStart, measuredEnd)
        let end = max(measuredEnd, start + 1)
        let recorded = max(end, nowEpochMs())
        return BenchmarkCaseEventBase(
            runID: runID,
            caseID: caseID,
            stage: stage,
            status: status,
            startedAtMs: start,
            endedAtMs: end,
            recordedAtMs: recorded
        )
    }

    static func makeEventBase(
        runID: String,
        caseID: String,
        stage: BenchmarkEventStage,
        status: BenchmarkEventStatus,
        seed: Int
    ) -> BenchmarkCaseEventBase {
        let seedValue = Int64(seed)
        let caseStart = seedValue > 1_000_000_000_000 ? seedValue : nowEpochMs()
        return makeEventBase(
            runID: runID,
            caseID: caseID,
            stage: stage,
            status: status,
            startedAtMs: caseStart,
            endedAtMs: nowEpochMs()
        )
    }

    @discardableResult
    static func saveBenchmarkRun(
        runID: String,
        kind: BenchmarkKind,
        options: BenchmarkRunOptions,
        metrics: BenchmarkRunMetrics,
        caseResults: [BenchmarkCaseResult],
        events: [BenchmarkCaseEvent],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> BenchmarkRunRecord {
        let recorder = try BenchmarkRunRecorder(
            runID: runID,
            kind: kind,
            options: options,
            initialMetrics: metrics,
            environment: environment
        )
        for result in caseResults {
            try recorder.appendCaseResult(result)
        }
        try recorder.appendEvents(events)
        return try recorder.finalize(metrics: metrics, options: options, status: .completed)
    }

    static func benchmarkCacheRootURL() -> URL {
        (try? WhispPaths().benchmarkCacheDirectory)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("whisp-benchmark-cache", isDirectory: true)
    }

    static func cacheFileURL(component: String, key: String) -> URL {
        benchmarkCacheRootURL()
            .appendingPathComponent(component, isDirectory: true)
            .appendingPathComponent("\(key).json", isDirectory: false)
    }

    static func loadCacheEntry<T: Decodable>(component: String, key: String) -> T? {
        let url = cacheFileURL(component: component, key: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func saveCacheEntry<T: Encodable>(component: String, key: String, value: T) throws {
        let url = cacheFileURL(component: component, key: key)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    static func sha256Hex(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(text: String) -> String {
        sha256Hex(data: Data(text.utf8))
    }

    static func canonicalContextString(_ context: ContextInfo?) -> String {
        guard let context else { return "{}" }
        let payload: [String: Any] = [
            "accessibilityText": context.accessibilityText ?? "",
            "windowText": context.windowText ?? "",
            "visionSummary": context.visionSummary ?? "",
            "visionTerms": context.visionTerms,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    static func inferImageMimeType(path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "webp":
            return "image/webp"
        default:
            return "image/jpeg"
        }
    }

    static func termSetScore(reference: [String], hypothesis: [String]) -> TermScore {
        let refSet = Set(reference.map(normalizedTerm))
        let hypSet = Set(hypothesis.map(normalizedTerm))
        if refSet.isEmpty, hypSet.isEmpty {
            return TermScore(precision: 1, recall: 1, f1: 1)
        }
        if hypSet.isEmpty {
            return TermScore(precision: 0, recall: 0, f1: 0)
        }
        let intersection = refSet.intersection(hypSet).count
        let precision = Double(intersection) / Double(max(1, hypSet.count))
        let recall = Double(intersection) / Double(max(1, refSet.count))
        let denom = precision + recall
        let f1 = denom > 0 ? (2 * precision * recall / denom) : 0
        return TermScore(precision: precision, recall: recall, f1: f1)
    }

    static func normalizedTerm(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func benchmarkManifestPath(
        runID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        URL(fileURLWithPath: BenchmarkStore(environment: environment).runsDirectoryPath, isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
            .path
    }
}
