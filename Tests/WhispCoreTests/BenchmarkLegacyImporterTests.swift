import Foundation
import XCTest
@testable import WhispCore

final class BenchmarkLegacyImporterTests: XCTestCase {
    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testImportSTTLegacyLogsCreatesRunCasesEvents() throws {
        let home = tempHome()
        let store = BenchmarkStore(environment: ["HOME": home.path])
        let importer = BenchmarkLegacyImporter(store: store)

        let logDir = home.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let rowsPath = logDir.appendingPathComponent("stt_case_rows.jsonl").path
        let summaryPath = logDir.appendingPathComponent("stt_summary.json").path

        let rowObject: [String: Any] = [
            "id": "case-001",
            "status": "ok",
            "cached": true,
            "transcriptReferenceSource": "labels.transcript_gold",
            "exactMatch": false,
            "cer": 0.12,
            "sttTotalMs": 321.5,
            "sttAfterStopMs": 120.0,
            "audioSeconds": 4.2,
        ]
        let rowData = try JSONSerialization.data(withJSONObject: rowObject, options: [.sortedKeys])
        try rowData.write(to: URL(fileURLWithPath: rowsPath), options: [.atomic])

        let summaryObject: [String: Any] = [
            "generatedAt": "2026-02-11T00:00:00Z",
            "benchmark": "stt",
            "jsonlPath": "/tmp/manual.jsonl",
            "casesTotal": 1,
            "casesSelected": 1,
            "executedCases": 1,
            "skippedCases": 0,
            "failedCases": 0,
            "cachedHits": 1,
            "exactMatchRate": 0.0,
            "avgCER": 0.12,
            "weightedCER": 0.12,
            "llmEvalEnabled": false,
            "llmEvalEvaluatedCases": 0,
            "llmEvalErrorCases": 0,
            "latencyMs": ["avg": 321.5, "p50": 321.5, "p95": 321.5, "p99": 321.5],
            "afterStopLatencyMs": ["avg": 120.0, "p50": 120.0, "p95": 120.0, "p99": 120.0],
        ]
        let summaryData = try JSONSerialization.data(withJSONObject: summaryObject, options: [.sortedKeys])
        try summaryData.write(to: URL(fileURLWithPath: summaryPath), options: [.atomic])

        let run = try importer.importRun(input: BenchmarkLegacyImportInput(
            kind: .stt,
            rowsPath: rowsPath,
            summaryPath: summaryPath,
            logDirectoryPath: logDir.path,
            options: BenchmarkRunOptions(
                sourceCasesPath: "/tmp/manual.jsonl",
                sttMode: "stream",
                useCache: true
            )
        ))

        XCTAssertEqual(run.kind, .stt)
        XCTAssertEqual(run.metrics.executedCases, 1)
        XCTAssertEqual(run.metrics.cachedHits, 1)

        let cases = try store.loadCaseResults(runID: run.id)
        XCTAssertEqual(cases.count, 1)
        XCTAssertEqual(cases.first?.id, "case-001")
        XCTAssertEqual(cases.first?.cache?.hit, true)

        let events = try store.loadEvents(runID: run.id, caseID: "case-001")
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.contains { $0.base.stage == .loadCase })
        XCTAssertTrue(events.contains { $0.base.stage == .cache })
        XCTAssertTrue(events.contains { $0.base.stage == .aggregate })
    }

    func testImportRunGeneratesUniqueRunIDForBackToBackImports() throws {
        let home = tempHome()
        let store = BenchmarkStore(environment: ["HOME": home.path])
        let importer = BenchmarkLegacyImporter(store: store)

        let logDir = home.appendingPathComponent("legacy-unique", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let rowsPath = logDir.appendingPathComponent("stt_case_rows.jsonl").path
        let summaryPath = logDir.appendingPathComponent("stt_summary.json").path

        let rowObject: [String: Any] = [
            "id": "case-001",
            "status": "ok",
            "cached": false,
            "exactMatch": true,
            "cer": 0.0,
            "sttTotalMs": 100.0,
            "sttAfterStopMs": 40.0,
        ]
        let rowData = try JSONSerialization.data(withJSONObject: rowObject, options: [.sortedKeys])
        try rowData.write(to: URL(fileURLWithPath: rowsPath), options: [.atomic])

        let summaryObject: [String: Any] = [
            "generatedAt": "2026-02-11T00:00:00Z",
            "benchmark": "stt",
            "jsonlPath": "/tmp/manual.jsonl",
            "casesTotal": 1,
            "casesSelected": 1,
            "executedCases": 1,
            "skippedCases": 0,
            "failedCases": 0,
            "cachedHits": 0,
            "exactMatchRate": 1.0,
            "avgCER": 0.0,
            "weightedCER": 0.0,
            "llmEvalEnabled": false,
            "llmEvalEvaluatedCases": 0,
            "llmEvalErrorCases": 0,
            "latencyMs": ["avg": 100.0, "p50": 100.0, "p95": 100.0, "p99": 100.0],
            "afterStopLatencyMs": ["avg": 40.0, "p50": 40.0, "p95": 40.0, "p99": 40.0],
        ]
        let summaryData = try JSONSerialization.data(withJSONObject: summaryObject, options: [.sortedKeys])
        try summaryData.write(to: URL(fileURLWithPath: summaryPath), options: [.atomic])

        let run1 = try importer.importRun(input: BenchmarkLegacyImportInput(
            kind: .stt,
            rowsPath: rowsPath,
            summaryPath: summaryPath,
            logDirectoryPath: logDir.path,
            options: BenchmarkRunOptions(sourceCasesPath: "/tmp/manual.jsonl", sttMode: "stream")
        ))
        let run2 = try importer.importRun(input: BenchmarkLegacyImportInput(
            kind: .stt,
            rowsPath: rowsPath,
            summaryPath: summaryPath,
            logDirectoryPath: logDir.path,
            options: BenchmarkRunOptions(sourceCasesPath: "/tmp/manual.jsonl", sttMode: "stream")
        ))

        XCTAssertNotEqual(run1.id, run2.id)
        XCTAssertEqual(try store.loadCaseResults(runID: run1.id).count, 1)
        XCTAssertEqual(try store.loadCaseResults(runID: run2.id).count, 1)
    }

    func testImportE2ESummaryUsesManualSchema() throws {
        let home = tempHome()
        let store = BenchmarkStore(environment: ["HOME": home.path])
        let importer = BenchmarkLegacyImporter(store: store)

        let logDir = home.appendingPathComponent("legacy-e2e", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let rowsPath = logDir.appendingPathComponent("manual_case_rows.jsonl").path
        let summaryPath = logDir.appendingPathComponent("manual_summary.json").path

        let rowObject: [String: Any] = [
            "id": "case-100",
            "status": "ok",
            "cached": false,
            "exactMatch": true,
            "cer": 0.0,
            "sttTotalMs": 200.0,
            "sttAfterStopMs": 80.0,
            "postMs": 40.0,
            "totalAfterStopMs": 120.0,
        ]
        let rowData = try JSONSerialization.data(withJSONObject: rowObject, options: [.sortedKeys])
        try rowData.write(to: URL(fileURLWithPath: rowsPath), options: [.atomic])

        let summaryObject: [String: Any] = [
            "generatedAt": "2026-02-11T00:00:00Z",
            "jsonlPath": "/tmp/manual.jsonl",
            "sttMode": "stream",
            "chunkMs": 120,
            "realtime": true,
            "requireContext": false,
            "minAudioSeconds": 0.0,
            "intentSource": "auto",
            "intentJudgeEnabled": false,
            "llmEvalEnabled": true,
            "llmEvalEvaluatedCases": 1,
            "llmEvalErrorCases": 0,
            "casesTotal": 1,
            "casesSelected": 1,
            "executedCases": 1,
            "skippedMissingAudio": 0,
            "skippedInvalidAudio": 0,
            "skippedMissingReferenceTranscript": 0,
            "skippedMissingContext": 0,
            "skippedTooShortAudio": 0,
            "skippedLowLabelConfidence": 0,
            "failedRuns": 0,
            "exactMatchRate": 1.0,
            "avgCER": 0.0,
            "weightedCER": 0.0,
            "intentPreservationScore": 0.95,
            "hallucinationScore": 0.97,
            "hallucinationRate": 0.03,
            "sttTotalMs": ["avg": 200.0, "p50": 200.0, "p95": 200.0, "p99": 200.0],
            "sttAfterStopMs": ["avg": 80.0, "p50": 80.0, "p95": 80.0, "p99": 80.0],
            "postMs": ["avg": 40.0, "p50": 40.0, "p95": 40.0, "p99": 40.0],
            "totalAfterStopMs": ["avg": 120.0, "p50": 120.0, "p95": 120.0, "p99": 120.0],
        ]
        let summaryData = try JSONSerialization.data(withJSONObject: summaryObject, options: [.sortedKeys])
        try summaryData.write(to: URL(fileURLWithPath: summaryPath), options: [.atomic])

        let run = try importer.importRun(input: BenchmarkLegacyImportInput(
            kind: .e2e,
            rowsPath: rowsPath,
            summaryPath: summaryPath,
            logDirectoryPath: logDir.path,
            options: BenchmarkRunOptions(sourceCasesPath: "/tmp/manual.jsonl")
        ))

        XCTAssertEqual(run.metrics.executedCases, 1)
        XCTAssertEqual(run.metrics.skippedCases, 0)
        XCTAssertEqual(run.metrics.failedCases, 0)
        XCTAssertEqual(run.metrics.cachedHits, 0)
        XCTAssertEqual(run.metrics.latencyMs?.p50, 200.0)
        XCTAssertEqual(run.metrics.afterStopLatencyMs?.p50, 80.0)
        XCTAssertEqual(run.metrics.postLatencyMs?.p50, 40.0)
        XCTAssertEqual(run.metrics.totalAfterStopLatencyMs?.p50, 120.0)
    }

    func testImportRejectsSummaryWithoutRequiredCurrentSchemaFields() throws {
        let home = tempHome()
        let store = BenchmarkStore(environment: ["HOME": home.path])
        let importer = BenchmarkLegacyImporter(store: store)

        let logDir = home.appendingPathComponent("legacy-invalid", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let rowsPath = logDir.appendingPathComponent("stt_case_rows.jsonl").path
        let summaryPath = logDir.appendingPathComponent("stt_summary.json").path

        let rowObject: [String: Any] = [
            "id": "case-001",
            "status": "ok",
            "cached": false,
        ]
        let rowData = try JSONSerialization.data(withJSONObject: rowObject, options: [.sortedKeys])
        try rowData.write(to: URL(fileURLWithPath: rowsPath), options: [.atomic])

        // intentionally missing generatedAt / benchmark / jsonlPath / llmEval* fields
        let summaryObject: [String: Any] = [
            "casesTotal": 1,
            "casesSelected": 1,
            "executedCases": 1,
            "skippedCases": 0,
            "failedCases": 0,
            "cachedHits": 0,
        ]
        let summaryData = try JSONSerialization.data(withJSONObject: summaryObject, options: [.sortedKeys])
        try summaryData.write(to: URL(fileURLWithPath: summaryPath), options: [.atomic])

        XCTAssertThrowsError(try importer.importRun(input: BenchmarkLegacyImportInput(
            kind: .stt,
            rowsPath: rowsPath,
            summaryPath: summaryPath,
            logDirectoryPath: logDir.path,
            options: BenchmarkRunOptions(sourceCasesPath: "/tmp/manual.jsonl")
        )))
    }
}
