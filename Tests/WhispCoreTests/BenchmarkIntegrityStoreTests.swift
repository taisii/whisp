import Foundation
import XCTest
@testable import WhispCore

final class BenchmarkIntegrityStoreTests: XCTestCase {
    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSaveLoadAndExcludeIssues() throws {
        let home = tempHome()
        let store = BenchmarkIntegrityStore(environment: ["HOME": home.path])

        let issue = BenchmarkIntegrityIssue(
            id: "issue-a",
            caseID: "case-a",
            task: .generation,
            issueType: "missing_stt_text",
            missingFields: ["stt_text"],
            sourcePath: "/tmp/manual.jsonl",
            excluded: false,
            detectedAt: "2026-02-12T00:00:00.000Z"
        )

        try store.saveIssues(task: .generation, issues: [issue])
        let loaded = try store.loadIssues(task: .generation)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.issueType, "missing_stt_text")
        XCTAssertEqual(loaded.first?.excluded, false)

        try store.setExcluded(issueID: "issue-a", task: .generation, excluded: true)
        let excluded = try store.loadIssues(task: .generation)
        XCTAssertEqual(excluded.first?.excluded, true)

        try store.setExcluded(issueID: "issue-a", task: .generation, excluded: false)
        let unexcluded = try store.loadIssues(task: .generation)
        XCTAssertEqual(unexcluded.first?.excluded, false)
    }

    func testSaveLoadAndClearAutoScanState() throws {
        let home = tempHome()
        let store = BenchmarkIntegrityStore(environment: ["HOME": home.path])

        let state = BenchmarkIntegrityAutoScanState(
            sourcePath: "/tmp/manual.jsonl",
            fingerprintsByCaseID: [
                "case-1": "fp-1",
                "case-2": "fp-2",
            ],
            lastScannedAt: "2026-02-14T00:00:00.000Z"
        )
        try store.saveAutoScanState(state)

        let loaded = try store.loadAutoScanState()
        XCTAssertEqual(loaded, state)

        try store.clearAutoScanState()
        XCTAssertNil(try store.loadAutoScanState())
    }
}
