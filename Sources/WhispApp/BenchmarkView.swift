import AppKit
import SwiftUI
import WhispCore

struct BenchmarkView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                runPane
                Divider()
                casePane
                Divider()
                eventPane
            }
            Divider()
            statusBar
        }
        .onAppear {
            viewModel.refresh()
        }
        .frame(minWidth: 1320, minHeight: 780)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Benchmark Lab")
                    .font(.system(size: 18, weight: .semibold))
                Text("Run / Case / Event を分離保存したベンチマーク閲覧")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
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

    private var runPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runs")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.top, 10)

            List(selection: Binding(get: {
                viewModel.selectedRunID
            }, set: { newValue in
                viewModel.selectRun(runID: newValue)
            })) {
                ForEach(viewModel.runs) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(shortID(run.id))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .help(run.id)
                            Spacer()
                            runStatusBadge(run.status)
                        }
                        Text("kind: \(run.kind.rawValue)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(run.createdAt)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .tag(run.id)
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 310, maxWidth: 360)
    }

    private var casePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cases")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.top, 10)

            List(selection: Binding(get: {
                viewModel.selectedCaseID
            }, set: { newValue in
                viewModel.selectCase(caseID: newValue)
            })) {
                ForEach(viewModel.cases) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.id)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Spacer()
                            caseStatusBadge(item.status)
                        }
                        if let cer = item.metrics.cer {
                            Text("cer: \(String(format: "%.3f", cer))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if let latency = item.metrics.totalAfterStopMs {
                            Text("total_after_stop_ms: \(String(format: "%.1f", latency))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(item.id)
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 320, maxWidth: 400)
    }

    private var eventPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Events")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)

            if let run = viewModel.selectedRun {
                runMetricsPanel(run: run)
                    .padding(.horizontal, 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(viewModel.events.enumerated()), id: \.offset) { index, event in
                        Button {
                            viewModel.selectEvent(index: index)
                        } label: {
                            HStack(spacing: 8) {
                                Text(event.base.stage.rawValue)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Text(event.base.status.rawValue)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("+\(relativeStartedMs(event))ms")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(index == viewModel.selectedEventIndex ? Color.accentColor.opacity(0.12) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(minHeight: 220, maxHeight: 280)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Artifacts")
                    .font(.system(size: 12, weight: .semibold))
                if viewModel.artifactPanels.isEmpty {
                    Text("このイベントに紐づく保存済みアーティファクトはありません。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.artifactPanels) { panel in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(panel.title)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            ScrollView {
                                Text(panel.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(panel.isError ? Color.red : Color.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(minHeight: 110, maxHeight: 180)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Spacer(minLength: 0)
        }
        .frame(minWidth: 560)
    }

    private func runMetricsPanel(run: BenchmarkRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run Metrics")
                .font(.system(size: 12, weight: .semibold))

            HStack(spacing: 14) {
                metricText("exact_match_rate", value: percent(run.metrics.exactMatchRate))
                metricText("avg_cer", value: decimal(run.metrics.avgCER))
                metricText("weighted_cer", value: decimal(run.metrics.weightedCER))
                metricText("avg_terms_f1", value: decimal(run.metrics.avgTermsF1))
                metricText("intent_match_rate", value: percent(run.metrics.intentMatchRate))
            }
            HStack(spacing: 14) {
                metricText("intent_preservation", value: decimal(run.metrics.intentPreservationScore))
                metricText("hallucination_score", value: decimal(run.metrics.hallucinationScore))
                metricText("hallucination_rate", value: decimal(run.metrics.hallucinationRate))
            }

            let rows = latencyRows(for: run)
            if rows.isEmpty {
                Text("latency: n/a")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.0) { label, distribution in
                    Text("\(label): avg=\(decimal(distribution.avg)) p50=\(decimal(distribution.p50)) p95=\(decimal(distribution.p95)) p99=\(decimal(distribution.p99))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    private func latencyRows(for run: BenchmarkRunRecord) -> [(String, BenchmarkLatencyDistribution)] {
        var rows: [(String, BenchmarkLatencyDistribution)] = []
        if let distribution = run.metrics.latencyMs {
            let label: String
            switch run.kind {
            case .stt:
                label = "stt_total_ms"
            case .vision:
                label = "vision_latency_ms"
            case .generation:
                label = "generation_latency_ms"
            case .e2e:
                label = "e2e_latency_ms"
            }
            rows.append((label, distribution))
        }
        if let distribution = run.metrics.afterStopLatencyMs {
            rows.append(("stt_after_stop_ms", distribution))
        }
        if let distribution = run.metrics.postLatencyMs {
            rows.append(("post_ms", distribution))
        }
        if let distribution = run.metrics.totalAfterStopLatencyMs {
            rows.append(("total_after_stop_ms", distribution))
        }
        return rows
    }

    private func metricText(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private func decimal(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.3f", value)
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f%%", value * 100)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(viewModel.statusIsError ? Color.orange : Color.secondary)
            Text(viewModel.statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(viewModel.statusIsError ? Color.red : Color.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func shortID(_ id: String) -> String {
        if id.count <= 16 {
            return id
        }
        return "\(id.prefix(8))...\(id.suffix(6))"
    }

    private func relativeStartedMs(_ event: BenchmarkCaseEvent) -> Int64 {
        guard let first = viewModel.events.first else {
            return 0
        }
        return max(Int64(0), event.base.startedAtMs - first.base.startedAtMs)
    }

    private func runStatusBadge(_ status: BenchmarkRunStatus) -> some View {
        Text(status.rawValue)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(runStatusColor(status).opacity(0.16))
            .foregroundStyle(runStatusColor(status))
            .clipShape(Capsule())
    }

    private func runStatusColor(_ status: BenchmarkRunStatus) -> Color {
        switch status {
        case .running:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private func caseStatusBadge(_ status: BenchmarkCaseStatus) -> some View {
        Text(status.rawValue)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(caseStatusColor(status).opacity(0.16))
            .foregroundStyle(caseStatusColor(status))
            .clipShape(Capsule())
    }

    private func caseStatusColor(_ status: BenchmarkCaseStatus) -> Color {
        switch status {
        case .ok:
            return .green
        case .skipped:
            return .orange
        case .error:
            return .red
        }
    }
}
