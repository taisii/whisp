import Foundation
import WhispCore

@MainActor
final class StatisticsViewModel: ObservableObject {
    @Published var selectedWindow: RuntimeStatsWindow = .last24Hours
    @Published private(set) var snapshot: RuntimeStatsSnapshot?
    @Published var statusMessage = ""
    @Published var statusIsError = false

    private let store: RuntimeStatsStore

    init(store: RuntimeStatsStore) {
        self.store = store
    }

    var selectedSummary: RuntimeStatsWindowSummary {
        snapshot?.summary(for: selectedWindow) ?? RuntimeStatsWindowSummary(
            totalRuns: 0,
            completedRuns: 0,
            skippedRuns: 0,
            failedRuns: 0,
            avgSttMs: nil,
            avgPostMs: nil,
            avgVisionMs: nil,
            avgDirectInputMs: nil,
            avgTotalAfterStopMs: nil,
            dominantStage: nil
        )
    }

    var updatedAt: String {
        snapshot?.updatedAt ?? "n/a"
    }

    func refresh() {
        snapshot = store.snapshot()
        statusIsError = false
        statusMessage = "統計を更新しました。"
    }
}
