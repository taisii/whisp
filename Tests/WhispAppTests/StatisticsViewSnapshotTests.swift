import AppKit
import SwiftUI
import XCTest
import WhispCore
@testable import WhispApp

@MainActor
final class StatisticsViewSnapshotTests: XCTestCase {
    private let width = 980
    private let height = 620

    func testRenderStatisticsViewBeforeAfter() throws {
        let artifactDir = try makeArtifactDirectory()

        let emptyStore = try RuntimeStatsStore(path: tempStatsPath())
        let emptyViewModel = StatisticsViewModel(store: emptyStore)
        emptyViewModel.refresh()
        let before = try renderSnapshot(viewModel: emptyViewModel)
        let beforeURL = artifactDir.appendingPathComponent("statistics_view_before.png")
        try pngData(from: before).write(to: beforeURL, options: .atomic)

        let dataStore = try RuntimeStatsStore(path: tempStatsPath())
        let now = Date()
        try dataStore.record(entry: RuntimeStatsEntry(
            recordedAt: now.addingTimeInterval(-1800),
            outcome: .completed,
            sttMs: 180,
            postMs: 140,
            visionMs: 90,
            directInputMs: 20,
            totalAfterStopMs: 430
        ))
        try dataStore.record(entry: RuntimeStatsEntry(
            recordedAt: now.addingTimeInterval(-3600 * 30),
            outcome: .failed,
            sttMs: 240,
            postMs: nil,
            visionMs: nil,
            directInputMs: nil,
            totalAfterStopMs: 260
        ))
        let dataViewModel = StatisticsViewModel(store: dataStore)
        dataViewModel.refresh()
        let after = try renderSnapshot(viewModel: dataViewModel)
        let afterURL = artifactDir.appendingPathComponent("statistics_view_after.png")
        try pngData(from: after).write(to: afterURL, options: .atomic)

        XCTAssertTrue(FileManager.default.fileExists(atPath: beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterURL.path))
    }

    private func renderSnapshot(viewModel: StatisticsViewModel) throws -> NSBitmapImageRep {
        let root = StatisticsView(viewModel: viewModel)
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

    private func tempStatsPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("runtime_stats.json", isDirectory: false)
    }
}
