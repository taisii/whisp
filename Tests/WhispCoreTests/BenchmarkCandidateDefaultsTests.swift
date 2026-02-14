import XCTest
@testable import WhispCore

final class BenchmarkCandidateDefaultsTests: XCTestCase {
    func testEnsureSeededIfNeededAddsMissingDefaultsAfterInitialSeedCompleted() throws {
        let tempHome = try makeTempHomeDirectory()
        let store = BenchmarkCandidateStore(environment: ["HOME": tempHome.path])

        try store.saveCandidates([
            BenchmarkCandidate(
                id: "stt-deepgram-stream-default",
                task: .stt,
                model: "deepgram",
                options: ["stt_mode": "stream"],
                createdAt: "2026-02-01T00:00:00.000Z",
                updatedAt: "2026-02-01T00:00:00.000Z"
            ),
            BenchmarkCandidate(
                id: "stt-apple-speech-stream-default",
                task: .stt,
                model: "apple_speech",
                options: ["stt_mode": "stream"],
                createdAt: "2026-02-01T00:00:00.000Z",
                updatedAt: "2026-02-01T00:00:00.000Z"
            ),
        ])
        try store.markInitialSeedCompleted()

        try BenchmarkCandidateDefaults.ensureSeededIfNeeded(store: store)
        let ids = try store.listCandidates().map(\.id)

        XCTAssertTrue(ids.contains("stt-deepgram-stream-default"))
        XCTAssertTrue(ids.contains("stt-apple-speech-stream-default"))
        XCTAssertTrue(ids.contains("stt-whisper-stream-default"))
    }

    func testEnsureSeededIfNeededDoesNotDuplicateExistingCandidates() throws {
        let tempHome = try makeTempHomeDirectory()
        let store = BenchmarkCandidateStore(environment: ["HOME": tempHome.path])

        let defaults = BenchmarkCandidateDefaults.defaultCandidates(now: "2026-02-01T00:00:00.000Z")
        try store.saveCandidates(defaults)
        try store.markInitialSeedCompleted()

        try BenchmarkCandidateDefaults.ensureSeededIfNeeded(store: store)
        let ids = try store.listCandidates().map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.filter { $0 == "stt-whisper-stream-default" }.count, 1)
    }

    private func makeTempHomeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
