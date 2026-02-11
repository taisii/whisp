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
            "transcript_reference_source": "labels.transcript_gold",
            "exact_match": false,
            "cer": 0.12,
            "stt_total_ms": 321.5,
            "stt_after_stop_ms": 120.0,
            "audio_seconds": 4.2,
        ]
        let rowData = try JSONSerialization.data(withJSONObject: rowObject, options: [.sortedKeys])
        try rowData.write(to: URL(fileURLWithPath: rowsPath), options: [.atomic])

        let summaryObject: [String: Any] = [
            "cases_total": 1,
            "cases_selected": 1,
            "executed_cases": 1,
            "skipped_cases": 0,
            "failed_cases": 0,
            "cached_hits": 1,
            "exact_match_rate": 0.0,
            "avg_cer": 0.12,
            "weighted_cer": 0.12,
            "avg_stt_total_ms": 321.5,
            "avg_stt_after_stop_ms": 120.0,
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
            "exact_match": true,
            "cer": 0.0,
            "stt_total_ms": 100.0,
            "stt_after_stop_ms": 40.0,
        ]
        let rowData = try JSONSerialization.data(withJSONObject: rowObject, options: [.sortedKeys])
        try rowData.write(to: URL(fileURLWithPath: rowsPath), options: [.atomic])

        let summaryObject: [String: Any] = [
            "cases_total": 1,
            "cases_selected": 1,
            "executed_cases": 1,
            "skipped_cases": 0,
            "failed_cases": 0,
            "cached_hits": 0,
            "exact_match_rate": 1.0,
            "avg_cer": 0.0,
            "weighted_cer": 0.0,
            "avg_stt_total_ms": 100.0,
            "avg_stt_after_stop_ms": 40.0,
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
}
