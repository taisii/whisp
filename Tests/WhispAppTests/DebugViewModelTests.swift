import Foundation
import XCTest
import WhispCore
@testable import WhispApp

@MainActor
final class DebugViewModelTests: XCTestCase {
    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(home: URL) -> DebugCaptureStore {
        DebugCaptureStore(environment: ["HOME": home.path])
    }

    func testRefreshExcludesFailedAndSkippedRuns() throws {
        let home = tempHome()
        let store = makeStore(home: home)

        let completedCaptureID = try store.saveRecording(
            runID: "run-completed",
            sampleRate: 16_000,
            pcmData: Data(repeating: 1, count: 320),
            llmModel: "gpt-5-nano",
            appName: "Xcode"
        )
        try store.updateResult(
            captureID: completedCaptureID,
            sttText: "ok",
            outputText: "ok",
            status: "completed"
        )

        let failedCaptureID = try store.saveRecording(
            runID: "run-failed",
            sampleRate: 16_000,
            pcmData: Data(repeating: 2, count: 320),
            llmModel: "gpt-5-nano",
            appName: "Xcode"
        )
        try store.updateResult(
            captureID: failedCaptureID,
            sttText: "ng",
            outputText: nil,
            status: " FAILED ",
            errorMessage: "timeout"
        )

        let skippedCaptureID = try store.saveRecording(
            runID: "run-skipped",
            sampleRate: 16_000,
            pcmData: Data(repeating: 3, count: 320),
            llmModel: "gpt-5-nano",
            appName: "Xcode"
        )
        try store.updateResult(
            captureID: skippedCaptureID,
            sttText: nil,
            outputText: nil,
            status: " skipped ",
            skipReason: "empty_audio"
        )

        let viewModel = DebugViewModel(store: store)
        viewModel.refresh()

        XCTAssertEqual(viewModel.records.count, 1)
        XCTAssertEqual(viewModel.records.first?.id, completedCaptureID)
        XCTAssertEqual(viewModel.visibleCountText, "1 / 1")
        XCTAssertEqual(viewModel.selectedCaptureID, completedCaptureID)
        XCTAssertEqual(viewModel.details?.record.id, completedCaptureID)
    }
}
