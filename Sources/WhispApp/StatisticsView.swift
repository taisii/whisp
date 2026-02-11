import AppKit
import SwiftUI
import WhispCore

struct StatisticsView: View {
    @ObservedObject var viewModel: StatisticsViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 860, minHeight: 520)
        .onAppear {
            viewModel.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Runtime Statistics")
                    .font(.system(size: 18, weight: .semibold))
                Text("実録音ログを増分集計した運用統計")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("期間", selection: $viewModel.selectedWindow) {
                ForEach(RuntimeStatsWindow.allCases, id: \.self) { window in
                    Text(windowLabel(window))
                        .tag(window)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("再読み込み")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var content: some View {
        let summary = viewModel.selectedSummary
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Run Counts")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 10) {
                    summaryCard(title: "Total", value: "\(summary.totalRuns)")
                    summaryCard(title: "Completed", value: "\(summary.completedRuns)")
                    summaryCard(title: "Skipped", value: "\(summary.skippedRuns)")
                    summaryCard(title: "Failed", value: "\(summary.failedRuns)")
                }

                Text("Phase Averages")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 10) {
                    summaryCard(title: "STT", value: msText(summary.avgSttMs))
                    summaryCard(title: "Post", value: msText(summary.avgPostMs))
                    summaryCard(title: "Vision", value: msText(summary.avgVisionMs))
                }
                HStack(spacing: 10) {
                    summaryCard(title: "Direct Input", value: msText(summary.avgDirectInputMs))
                    summaryCard(title: "Total(Stop->End)", value: msText(summary.avgTotalAfterStopMs))
                    summaryCard(title: "Dominant Stage", value: stageLabel(summary.dominantStage))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(viewModel.statusIsError ? Color.orange : Color.secondary)
            Text(viewModel.statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(viewModel.statusIsError ? Color.red : Color.secondary)
            Spacer()
            Text("updated: \(viewModel.updatedAt)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func summaryCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    private func msText(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f ms", value)
    }

    private func stageLabel(_ value: RuntimeStatsStage?) -> String {
        guard let value else { return "n/a" }
        switch value {
        case .stt:
            return "STT"
        case .post:
            return "Post"
        case .vision:
            return "Vision"
        case .directInput:
            return "DirectInput"
        case .unknown:
            return "Unknown"
        }
    }

    private func windowLabel(_ window: RuntimeStatsWindow) -> String {
        switch window {
        case .last24Hours:
            return "24h"
        case .last7Days:
            return "7d"
        case .last30Days:
            return "30d"
        case .all:
            return "All"
        }
    }
}
