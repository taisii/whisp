import Foundation
import XCTest
@testable import WhispCore

final class BenchmarkCandidateStoreTests: XCTestCase {
    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSaveLoadAndUpsertCandidates() throws {
        let home = tempHome()
        let store = BenchmarkCandidateStore(environment: ["HOME": home.path])

        let candidate = BenchmarkCandidate(
            id: "stt-a",
            task: .stt,
            model: "deepgram",
            options: ["stt_mode": "stream"],
            createdAt: "2026-02-12T00:00:00.000Z",
            updatedAt: "2026-02-12T00:00:00.000Z"
        )
        try store.saveCandidates([candidate])

        let loaded = try store.listCandidates()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "stt-a")

        let updated = BenchmarkCandidate(
            id: "stt-a",
            task: .stt,
            model: "deepgram",
            options: ["stt_mode": "rest"],
            createdAt: candidate.createdAt,
            updatedAt: "2026-02-12T00:10:00.000Z"
        )
        try store.upsertCandidate(updated)

        let after = try store.loadCandidate(id: "stt-a")
        XCTAssertEqual(after?.options["stt_mode"], "rest")
    }

    func testSaveCandidatesRejectsDuplicateID() {
        let home = tempHome()
        let store = BenchmarkCandidateStore(environment: ["HOME": home.path])
        let now = "2026-02-12T00:00:00.000Z"

        let candidates = [
            BenchmarkCandidate(id: "dup", task: .stt, model: "deepgram", createdAt: now, updatedAt: now),
            BenchmarkCandidate(id: "dup", task: .generation, model: "gpt-5-nano", createdAt: now, updatedAt: now),
        ]

        XCTAssertThrowsError(try store.saveCandidates(candidates))
    }
}
