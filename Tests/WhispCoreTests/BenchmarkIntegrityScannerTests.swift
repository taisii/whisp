import XCTest
@testable import WhispCore

final class BenchmarkIntegrityScannerTests: XCTestCase {
    func testScanIssuesForDefaultTasks() {
        let cases = [
            BenchmarkIntegrityScanCase(
                id: "case-1",
                audioFile: "",
                sttText: "",
                groundTruthText: "",
                transcriptGold: nil,
                transcriptSilver: nil
            ),
            BenchmarkIntegrityScanCase(
                id: "case-2",
                audioFile: "/tmp/a.wav",
                sttText: "こんにちは",
                groundTruthText: "こんにちは",
                transcriptGold: nil,
                transcriptSilver: nil
            ),
        ]
        let scanned = BenchmarkIntegrityScanner.scanIssuesForDefaultTasks(
            cases: cases,
            sourcePath: "/tmp/manual.jsonl",
            detectedAt: "2026-02-14T00:00:00.000Z",
            fileExists: { _ in false }
        )

        XCTAssertEqual(scanned[.stt]?.count, 3)
        XCTAssertEqual(scanned[.generation]?.count, 2)
    }

    func testFingerprintChangesWhenCaseTextChanges() {
        let base = BenchmarkIntegrityScanCase(
            id: "case-1",
            audioFile: "/tmp/a.wav",
            sttText: "before",
            groundTruthText: "ground",
            transcriptGold: nil,
            transcriptSilver: nil
        )
        let updated = BenchmarkIntegrityScanCase(
            id: "case-1",
            audioFile: "/tmp/a.wav",
            sttText: "after",
            groundTruthText: "ground",
            transcriptGold: nil,
            transcriptSilver: nil
        )

        let beforeFingerprint = BenchmarkIntegrityScanner.fingerprint(case: base)
        let afterFingerprint = BenchmarkIntegrityScanner.fingerprint(case: updated)
        XCTAssertNotEqual(beforeFingerprint.value, afterFingerprint.value)
    }
}
