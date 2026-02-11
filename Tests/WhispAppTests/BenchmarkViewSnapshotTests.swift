import AppKit
import SwiftUI
import XCTest
import WhispCore
@testable import WhispApp

@MainActor
final class BenchmarkViewSnapshotTests: XCTestCase {
    private let width = 1360
    private let height = 820

    func testRenderBenchmarkViewBeforeAfter() throws {
        let artifactDir = try makeArtifactDirectory()

        let emptyHome = try makeTempHome()
        let emptyStore = BenchmarkStore(environment: ["HOME": emptyHome.path])
        let emptyViewModel = BenchmarkViewModel(store: emptyStore)
        emptyViewModel.refresh()
        let before = try renderSnapshot(viewModel: emptyViewModel)
        let beforeURL = artifactDir.appendingPathComponent("benchmark_view_before.png")
        try pngData(from: before).write(to: beforeURL, options: .atomic)

        let dataHome = try makeTempHome()
        let dataStore = BenchmarkStore(environment: ["HOME": dataHome.path])
        let runID = "snapshot-run"
        var paths = dataStore.resolveRunPaths(runID: runID)
        paths.logDirectoryPath = "/tmp/bench"
        paths.rowsFilePath = "/tmp/bench/rows.jsonl"
        paths.summaryFilePath = "/tmp/bench/summary.json"

        try dataStore.saveRun(
            BenchmarkRunRecord(
                id: runID,
                kind: .e2e,
                status: .completed,
                createdAt: "2026-02-11T00:00:00Z",
                updatedAt: "2026-02-11T00:01:00Z",
                options: BenchmarkRunOptions(sourceCasesPath: "/tmp/cases.jsonl", sttMode: "stream"),
                metrics: BenchmarkRunMetrics(
                    casesTotal: 1,
                    casesSelected: 1,
                    executedCases: 1,
                    skippedCases: 0,
                    failedCases: 0,
                    cachedHits: 1,
                    exactMatchRate: 0.0,
                    avgCER: 0.12
                ),
                paths: paths
            )
        )

        try dataStore.appendCaseResult(
            runID: runID,
            result: BenchmarkCaseResult(
                id: "case-1",
                status: .ok,
                cache: BenchmarkCacheRecord(hit: true, key: "abc", namespace: "generation"),
                sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold", intent: "labels.intent_gold"),
                contextUsed: true,
                visionImageAttached: true,
                metrics: BenchmarkCaseMetrics(
                    cer: 0.12,
                    intentMatch: true,
                    intentScore: 4,
                    totalAfterStopMs: 430
                )
            )
        )

        let requestRef = try dataStore.writeArtifact(
            runID: runID,
            caseID: "case-1",
            fileName: "request.txt",
            mimeType: "text/plain",
            data: Data("judge request payload".utf8)
        )

        let loadBase = BenchmarkCaseEventBase(
            runID: runID,
            caseID: "case-1",
            stage: .loadCase,
            status: .ok,
            startedAtMs: 1,
            endedAtMs: 2,
            recordedAtMs: 3
        )
        try dataStore.appendEvent(
            runID: runID,
            event: .loadCase(BenchmarkLoadCaseLog(
                base: loadBase,
                sources: BenchmarkReferenceSources(transcript: "labels.transcript_gold"),
                contextPresent: true,
                visionImagePresent: true,
                audioFilePath: nil,
                rawRowRef: nil
            ))
        )

        let judgeBase = BenchmarkCaseEventBase(
            runID: runID,
            caseID: "case-1",
            stage: .judge,
            status: .ok,
            startedAtMs: 4,
            endedAtMs: 5,
            recordedAtMs: 6
        )
        try dataStore.appendEvent(
            runID: runID,
            event: .judge(BenchmarkJudgeLog(
                base: judgeBase,
                model: "gpt-5-nano",
                match: true,
                score: 4,
                requestRef: requestRef,
                responseRef: nil,
                error: nil
            ))
        )

        let dataViewModel = BenchmarkViewModel(store: dataStore)
        dataViewModel.refresh()
        let after = try renderSnapshot(viewModel: dataViewModel)
        let afterURL = artifactDir.appendingPathComponent("benchmark_view_after.png")
        try pngData(from: after).write(to: afterURL, options: .atomic)

        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    private func renderSnapshot(viewModel: BenchmarkViewModel) throws -> NSBitmapImageRep {
        let root = BenchmarkView(viewModel: viewModel)
            .frame(width: CGFloat(width), height: CGFloat(height))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw AppError.io("failed to create bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    private func pngData(from bitmap: NSBitmapImageRep) throws -> Data {
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AppError.io("failed to encode png")
        }
        return png
    }

    private func makeArtifactDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = root.appendingPathComponent(".build/snapshot-artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
