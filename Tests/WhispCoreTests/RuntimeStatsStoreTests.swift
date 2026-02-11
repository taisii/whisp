import Foundation
import XCTest
@testable import WhispCore

final class RuntimeStatsStoreTests: XCTestCase {
    private func tempFileURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("runtime_stats.json", isDirectory: false)
    }

    func testRecordAndSnapshotRespectsWindows() throws {
        let base = Date(timeIntervalSince1970: 1_730_000_000)
        var now = base
        let store = try RuntimeStatsStore(path: tempFileURL(), now: { now })

        try store.record(entry: RuntimeStatsEntry(
            recordedAt: base.addingTimeInterval(-2 * 3600),
            outcome: .completed,
            sttMs: 120,
            postMs: 80,
            visionMs: 40,
            directInputMs: 10,
            totalAfterStopMs: 260
        ))
        try store.record(entry: RuntimeStatsEntry(
            recordedAt: base.addingTimeInterval(-26 * 3600),
            outcome: .failed,
            sttMs: 300,
            postMs: nil,
            visionMs: nil,
            directInputMs: nil,
            totalAfterStopMs: 310
        ))

        let snapshot = store.snapshot(now: base)
        XCTAssertEqual(snapshot.all.totalRuns, 2)
        XCTAssertEqual(snapshot.all.completedRuns, 1)
        XCTAssertEqual(snapshot.all.failedRuns, 1)
        XCTAssertEqual(snapshot.last24Hours.totalRuns, 1)
        XCTAssertEqual(snapshot.last24Hours.completedRuns, 1)
        XCTAssertEqual(snapshot.last24Hours.failedRuns, 0)
        XCTAssertEqual(snapshot.last7Days.totalRuns, 2)
        XCTAssertEqual(snapshot.last30Days.totalRuns, 2)

        XCTAssertEqual(snapshot.last24Hours.avgSttMs ?? 0, 120, accuracy: 0.0001)
        XCTAssertEqual(snapshot.last24Hours.avgPostMs ?? 0, 80, accuracy: 0.0001)
        XCTAssertEqual(snapshot.last24Hours.avgTotalAfterStopMs ?? 0, 260, accuracy: 0.0001)
        XCTAssertEqual(snapshot.all.avgSttMs ?? 0, 210, accuracy: 0.0001)
        XCTAssertEqual(snapshot.last24Hours.dominantStage, .stt)
        XCTAssertEqual(snapshot.all.dominantStage, .stt)

        now = base.addingTimeInterval(8 * 24 * 3600)
        let future = store.snapshot()
        XCTAssertEqual(future.last7Days.totalRuns, 0)
        XCTAssertEqual(future.last30Days.totalRuns, 2)
    }

    func testRecordPersistsAcrossReload() throws {
        let base = Date(timeIntervalSince1970: 1_730_500_000)
        let path = tempFileURL()
        var now = base

        do {
            let store = try RuntimeStatsStore(path: path, now: { now })
            try store.record(entry: RuntimeStatsEntry(
                recordedAt: base,
                outcome: .skipped,
                sttMs: nil,
                postMs: nil,
                visionMs: nil,
                directInputMs: nil,
                totalAfterStopMs: 50
            ))
        }

        now = base.addingTimeInterval(3600)
        let reloaded = try RuntimeStatsStore(path: path, now: { now })
        let snapshot = reloaded.snapshot()
        XCTAssertEqual(snapshot.all.totalRuns, 1)
        XCTAssertEqual(snapshot.all.skippedRuns, 1)
        XCTAssertEqual(snapshot.all.avgTotalAfterStopMs ?? 0, 50, accuracy: 0.0001)
    }
}
