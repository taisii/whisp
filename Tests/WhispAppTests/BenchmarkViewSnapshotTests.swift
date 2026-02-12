import AppKit
import CryptoKit
import SwiftUI
import XCTest
import WhispCore
@testable import WhispApp

@MainActor
final class BenchmarkViewSnapshotTests: XCTestCase {
    private let width = 1460
    private let height = 900

    func testRenderBenchmarkViewBeforeAfter() throws {
        let artifactDir = try makeArtifactDirectory()

        let emptyHome = try makeTempHome()
        let emptyStore = BenchmarkStore(environment: ["HOME": emptyHome.path])
        let emptyCandidateStore = BenchmarkCandidateStore(environment: ["HOME": emptyHome.path])
        let emptyIntegrityStore = BenchmarkIntegrityStore(environment: ["HOME": emptyHome.path])
        let emptyViewModel = BenchmarkViewModel(
            store: emptyStore,
            candidateStore: emptyCandidateStore,
            integrityStore: emptyIntegrityStore
        )
        emptyViewModel.refresh()
        let before = try renderSnapshot(viewModel: emptyViewModel)
        let beforeURL = artifactDir.appendingPathComponent("benchmark_view_before.png")
        try pngData(from: before).write(to: beforeURL, options: .atomic)

        let dataHome = try makeTempHome()
        let env = ["HOME": dataHome.path]
        let dataStore = BenchmarkStore(environment: env)
        let dataCandidateStore = BenchmarkCandidateStore(environment: env)
        let dataIntegrityStore = BenchmarkIntegrityStore(environment: env)

        let casesPath = dataHome.appendingPathComponent("cases.jsonl", isDirectory: false)
        try Data("{}\n".utf8).write(to: casesPath, options: .atomic)

        let candidate = BenchmarkCandidate(
            id: "generation-gpt-5-nano-a",
            task: .generation,
            model: "gpt-5-nano",
            promptProfileID: "business",
            options: ["require_context": "true", "llm_eval": "true"],
            createdAt: "2026-02-12T00:00:00.000Z",
            updatedAt: "2026-02-12T00:00:00.000Z"
        )
        try dataCandidateStore.saveCandidates([candidate])

        let runID = "generation-20260212-000000-aaaa1111"
        let paths = dataStore.resolveRunPaths(runID: runID)
        try dataStore.saveRun(
            BenchmarkRunRecord(
                id: runID,
                kind: .generation,
                status: .completed,
                createdAt: "2026-02-12T00:00:00.000Z",
                updatedAt: "2026-02-12T00:00:00.000Z",
                options: BenchmarkRunOptions(
                    sourceCasesPath: casesPath.path,
                    datasetHash: "hash-a",
                    candidateID: candidate.id,
                    llmModel: "gpt-5-nano"
                ),
                candidateID: candidate.id,
                benchmarkKey: BenchmarkKey(
                    task: .generation,
                    datasetPath: casesPath.path,
                    datasetHash: "hash-a",
                    candidateID: candidate.id,
                    runtimeOptionsHash: "runtime-a",
                    evaluatorVersion: "v1",
                    codeVersion: "dev"
                ),
                metrics: BenchmarkRunMetrics(
                    casesTotal: 2,
                    casesSelected: 2,
                    executedCases: 2,
                    skippedCases: 0,
                    failedCases: 0,
                    avgCER: 0.2,
                    weightedCER: 0.24,
                    postLatencyMs: BenchmarkLatencyDistribution(avg: 110, p50: 100, p95: 180, p99: 210)
                ),
                paths: paths
            )
        )

        try dataStore.appendCaseResult(
            runID: runID,
            result: BenchmarkCaseResult(
                id: "case-1",
                status: .ok,
                reason: nil,
                cache: BenchmarkCacheRecord(hit: true, key: "abc", namespace: "generation"),
                sources: BenchmarkReferenceSources(input: "stt_text", reference: "ground_truth_text"),
                contextUsed: true,
                visionImageAttached: false,
                metrics: BenchmarkCaseMetrics(cer: 0.2, postMs: 140, outputChars: 120)
            )
        )

        let issue = BenchmarkIntegrityIssue(
            id: "issue-1",
            caseID: "case-2",
            task: .generation,
            issueType: "missing_stt_text",
            missingFields: ["stt_text"],
            sourcePath: casesPath.path,
            excluded: false,
            detectedAt: "2026-02-12T00:00:00.000Z"
        )
        try dataIntegrityStore.saveIssues(task: .generation, issues: [issue])

        let dataViewModel = BenchmarkViewModel(
            store: dataStore,
            candidateStore: dataCandidateStore,
            integrityStore: dataIntegrityStore,
            datasetPathOverride: casesPath.path
        )
        dataViewModel.selectedTask = .generation
        dataViewModel.refresh()
        let after = try renderSnapshot(viewModel: dataViewModel)
        let afterURL = artifactDir.appendingPathComponent("benchmark_view_after.png")
        try pngData(from: after).write(to: afterURL, options: .atomic)

        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    func testRenderBenchmarkErrorStatusChipBeforeAfter() throws {
        let artifactDir = try makeArtifactDirectory()
        let home = try makeTempHome()
        let env = ["HOME": home.path]
        let viewModel = BenchmarkViewModel(
            store: BenchmarkStore(environment: env),
            candidateStore: BenchmarkCandidateStore(environment: env),
            integrityStore: BenchmarkIntegrityStore(environment: env)
        )
        viewModel.refresh()

        viewModel.statusIsError = true
        viewModel.statusMessage = "比較実行に失敗"
        viewModel.benchmarkErrorLog = ""
        let before = try renderSnapshot(viewModel: viewModel)
        let beforeURL = artifactDir.appendingPathComponent("benchmark_error_chip_before.png")
        try pngData(from: before).write(to: beforeURL, options: .atomic)

        viewModel.benchmarkErrorLog = """
        io error: benchmark command failed (exit: 1)
        building...
        error: API key not found
        """
        let after = try renderSnapshot(viewModel: viewModel)
        let afterURL = artifactDir.appendingPathComponent("benchmark_error_chip_after.png")
        try pngData(from: after).write(to: afterURL, options: .atomic)

        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    func testRenderBenchmarkViewRoundTripTabSwitchKeepsLayout() throws {
        let artifactDir = try makeArtifactDirectory()
        let home = try makeTempHome()
        let env = ["HOME": home.path]
        let viewModel = BenchmarkViewModel(
            store: BenchmarkStore(environment: env),
            candidateStore: BenchmarkCandidateStore(environment: env),
            integrityStore: BenchmarkIntegrityStore(environment: env)
        )
        viewModel.refresh()

        viewModel.selectedTab = .comparison
        let before = try renderSnapshot(viewModel: viewModel)
        let beforeURL = artifactDir.appendingPathComponent("benchmark_roundtrip_comparison_before.png")
        try pngData(from: before).write(to: beforeURL, options: .atomic)

        viewModel.selectedTab = .integrity
        let integrity = try renderSnapshot(viewModel: viewModel)
        let integrityURL = artifactDir.appendingPathComponent("benchmark_roundtrip_integrity.png")
        try pngData(from: integrity).write(to: integrityURL, options: .atomic)

        viewModel.selectedTab = .comparison
        let after = try renderSnapshot(viewModel: viewModel)
        let afterURL = artifactDir.appendingPathComponent("benchmark_roundtrip_comparison_after.png")
        try pngData(from: after).write(to: afterURL, options: .atomic)

        XCTAssertEqual(imageDigest(before), imageDigest(after))
        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: integrityURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    private func renderSnapshot(viewModel: BenchmarkViewModel) throws -> NSBitmapImageRep {
        let root = BenchmarkView(viewModel: viewModel, autoRefreshOnAppear: false)
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

    private func imageDigest(_ bitmap: NSBitmapImageRep) -> String {
        let data = bitmap.tiffRepresentation ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
