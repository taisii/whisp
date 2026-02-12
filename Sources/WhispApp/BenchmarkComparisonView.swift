import SwiftUI
import WhispCore

struct BenchmarkComparisonView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    private let columnWidths: [CGFloat] = [220, 70, 110, 90, 90, 110, 110, 100, 150, 180, 110]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                controlBar
                Divider()

                HSplitView {
                    comparisonTable
                        .frame(minWidth: 980)

                    candidateDetail
                        .frame(minWidth: 360, maxWidth: 480)
                }

                Divider()
                caseBreakdown
                    .frame(minHeight: 220)
            }

            if viewModel.isCaseDetailPresented {
                caseDetailOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.isCaseDetailPresented)
    }

    private var caseDetailOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.dismissCaseDetail()
                }

            BenchmarkCaseDetailModal(viewModel: viewModel)
                .frame(minWidth: 860, idealWidth: 980, maxWidth: 1080, minHeight: 620, maxHeight: 780)
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
                .padding(32)
                .onTapGesture {
                    // 背景タップとの競合を避けるため、モーダル内タップは消費する。
                }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            Picker("Task", selection: $viewModel.selectedTask) {
                Text("STT").tag(BenchmarkKind.stt)
                Text("Generation").tag(BenchmarkKind.generation)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            TextField("Dataset path", text: $viewModel.datasetPath)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            Menu {
                if viewModel.taskCandidates.isEmpty {
                    Text("No candidates")
                } else {
                    ForEach(viewModel.taskCandidates, id: \.id) { candidate in
                        Button {
                            viewModel.toggleCandidateSelection(candidate.id)
                        } label: {
                            Label(candidate.id, systemImage: viewModel.selectedCandidateIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    Divider()
                    Button("Select All") {
                        viewModel.selectedCandidateIDs = Set(viewModel.taskCandidates.map(\.id))
                    }
                    Button("Clear") {
                        viewModel.selectedCandidateIDs.removeAll()
                    }
                }
            } label: {
                Text("Candidates \(viewModel.selectedCandidateIDs.count)/\(viewModel.taskCandidates.count)")
            }

            Toggle("Force rerun", isOn: $viewModel.forceRerun)
                .toggleStyle(.switch)

            Button {
                viewModel.runCompare()
            } label: {
                if viewModel.isExecutingBenchmark {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Running...")
                    }
                } else {
                    Label("Run compare", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isExecutingBenchmark)

            Button {
                viewModel.scanIntegrity()
            } label: {
                Label("Scan integrity", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isExecutingBenchmark)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var comparisonTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Comparison Table")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)

            ScrollView([.horizontal]) {
                VStack(spacing: 0) {
                    headerRow
                    Divider()
                    List(selection: Binding(get: {
                        viewModel.selectedComparisonCandidateID
                    }, set: { value in
                        viewModel.selectComparisonCandidate(value)
                    })) {
                        ForEach(viewModel.comparisonRows) { row in
                            comparisonRow(row)
                                .tag(row.id)
                        }
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 260)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            headerText("candidate_id", width: columnWidths[0])
            headerText("runs", width: columnWidths[1])
            headerText("executed_cases", width: columnWidths[2])
            headerText("skip_cases", width: columnWidths[3])
            headerText("avg_cer", width: columnWidths[4])
            headerText("weighted_cer", width: columnWidths[5])
            headerText("stt_after_stop_p95", width: columnWidths[6])
            headerText("post_ms_p95", width: columnWidths[7])
            headerText("total_after_stop_p95", width: columnWidths[8])
            headerText("last_run_at", width: columnWidths[9])
            headerText("dataset_hash_mismatch", width: columnWidths[10])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func comparisonRow(_ row: BenchmarkComparisonRow) -> some View {
        HStack(spacing: 8) {
            cellText(row.candidate.id, width: columnWidths[0])
            cellText("\(row.runs)", width: columnWidths[1])
            cellText("\(row.executedCases)", width: columnWidths[2])
            cellText("\(row.skipCases)", width: columnWidths[3])
            cellText(decimal(row.avgCER), width: columnWidths[4])
            cellText(decimal(row.weightedCER), width: columnWidths[5])
            cellText(ms(row.sttAfterStopP95), width: columnWidths[6])
            cellText(ms(row.postMsP95), width: columnWidths[7])
            cellText(ms(row.totalAfterStopP95), width: columnWidths[8])
            cellText(row.lastRunAt ?? "-", width: columnWidths[9])
            cellText(row.datasetHashMismatch ? "yes" : "no", width: columnWidths[10], color: row.datasetHashMismatch ? .orange : .secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 2)
    }

    private var candidateDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Candidate Detail")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)

            if let row = viewModel.selectedComparisonRow {
                VStack(alignment: .leading, spacing: 8) {
                    detailLine("candidate_id", row.candidate.id)
                    detailLine("task", row.candidate.task.rawValue)
                    detailLine("model", row.candidate.model)
                    detailLine("prompt_profile", row.candidate.promptProfileID ?? "-")
                    detailLine("latest_run", row.latestRunID ?? "-")
                    detailLine("last_run_at", row.lastRunAt ?? "-")

                    Divider()
                    Text("options")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    if row.candidate.options.isEmpty {
                        Text("-")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(row.candidate.options.keys.sorted(), id: \.self) { key in
                            detailLine(key, row.candidate.options[key] ?? "")
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                }
                .padding(.horizontal, 12)
            } else {
                Text("Candidateを選択してください。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }

            Spacer(minLength: 0)
        }
    }

    private var caseBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Case Breakdown")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 8)

            List {
                ForEach(viewModel.caseBreakdownRows) { row in
                    Button {
                        viewModel.openCaseDetail(caseID: row.id)
                    } label: {
                        HStack(spacing: 10) {
                            Text(row.id)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .frame(width: 180, alignment: .leading)
                            statusChip(row.status)
                            Text(decimal(row.cer))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 80, alignment: .trailing)
                            Text(ms(row.sttTotalMs))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 90, alignment: .trailing)
                            Text(ms(row.postMs))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 90, alignment: .trailing)
                            Text(ms(row.totalAfterStopMs))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 120, alignment: .trailing)
                            Text(row.reason ?? "-")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }
            .listStyle(.plain)
        }
        .padding(.bottom, 8)
    }

    private func headerText(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }

    private func cellText(_ value: String, width: CGFloat, color: Color = .primary) -> some View {
        Text(value)
            .foregroundStyle(color)
            .frame(width: width, alignment: .leading)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func detailLine(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private func statusChip(_ status: BenchmarkCaseStatus) -> some View {
        let color: Color
        switch status {
        case .ok:
            color = .green
        case .skipped:
            color = .orange
        case .error:
            color = .red
        }
        return Text(status.rawValue)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func decimal(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.3f", value)
    }

    private func ms(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.1f", value)
    }
}

private struct BenchmarkCaseDetailModal: View {
    @ObservedObject var viewModel: BenchmarkViewModel
    @State private var isMetricsExpanded = false

    var body: some View {
        Group {
            if let detail = viewModel.selectedCaseDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(detail)
                        audioSection(detail)
                        timelineSection(detail)
                        transcriptSection(detail)
                        metricsDisclosure(detail)
                        if !detail.missingDataMessages.isEmpty {
                            fallbackSection(detail)
                        }
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 8) {
                    Text("ケース詳細がありません")
                        .font(.system(size: 14, weight: .semibold))
                    Text("ケース行を選択して詳細を開いてください。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func header(_ detail: BenchmarkCaseDetail) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Case Detail")
                    .font(.system(size: 16, weight: .semibold))
                Text("case_id: \(detail.caseID)")
                    .font(.system(size: 11, design: .monospaced))
                Text("run_id: \(detail.runID)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("閉じる") {
                viewModel.dismissCaseDetail()
            }
            .buttonStyle(.bordered)
        }
    }

    private func audioSection(_ detail: BenchmarkCaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("音声")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                Button {
                    viewModel.toggleCaseAudioPlayback()
                } label: {
                    Label(
                        viewModel.isCaseAudioPlaying ? "停止" : "再生",
                        systemImage: viewModel.isCaseAudioPlaying ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)

                Text(detail.audioFilePath ?? "audio_file_path なし")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    private func timelineSection(_ detail: BenchmarkCaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("タイムライン")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 10) {
                metricChip("録音(ms)", ms(detail.recordingMs))
                metricChip("STT(ms)", ms(detail.sttMs))
                metricChip("差分(停止後待ちms)", ms(detail.sttDeltaAfterRecordingMs))
            }

            if let overlap = detail.timeline.overlap {
                Text("重なり: \(overlap.leftTitle) × \(overlap.rightTitle) \(ms(overlap.durationMs))ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if detail.timeline.phases.isEmpty || detail.timeline.totalMs <= 0 {
                Text("イベントが不足しているためタイムラインを表示できません。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(detail.timeline.phases) { phase in
                        timelineRow(phase: phase, totalMs: detail.timeline.totalMs)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    private func timelineRow(phase: BenchmarkCaseTimelinePhase, totalMs: Double) -> some View {
        HStack(spacing: 8) {
            Text(phase.title)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 170, alignment: .leading)

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let startRatio = max(0, min(1, phase.startMs / totalMs))
                let durationRatio = max(0.004, min(1, phase.durationMs / totalMs))
                let offset = width * startRatio
                let barWidth = max(3, width * durationRatio)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 14)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(phaseColor(phase.id))
                        .frame(width: barWidth, height: 14)
                        .offset(x: offset)
                }
            }
            .frame(height: 14)

            Text("\(ms(phase.durationMs))ms")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 88, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .help("\(phase.title)\n開始: \(ms(phase.startMs))ms / 終了: \(ms(phase.endMs))ms")
    }

    private func phaseColor(_ id: String) -> Color {
        switch id {
        case "audio_replay":
            return Color.blue.opacity(0.42)
        case "stt":
            return Color.blue
        case "stt_after_recording":
            return Color.orange
        default:
            return Color.secondary
        }
    }

    private func transcriptSection(_ detail: BenchmarkCaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STT結果と正解")
                .font(.system(size: 13, weight: .semibold))

            HStack(alignment: .top, spacing: 12) {
                transcriptPane(title: "STT結果", text: detail.sttText)
                transcriptPane(title: "STT正解", text: detail.referenceText)
            }
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    private func transcriptPane(title: String, text: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))

            ScrollView {
                Text((text ?? "").isEmpty ? "データ不足" : (text ?? ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(((text ?? "").isEmpty) ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 120)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricsDisclosure(_ detail: BenchmarkCaseDetail) -> some View {
        DisclosureGroup(isExpanded: $isMetricsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    metric("provider", detail.sttProvider ?? "-")
                    metric("route", detail.sttRoute ?? "-")
                    metric("cer", decimal(detail.cer))
                    metric("stt_total_ms", ms(detail.sttTotalMs))
                    metric("stt_after_stop_ms", ms(detail.sttAfterStopMs))
                }

                Text("attempt")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))

                if detail.attempts.isEmpty {
                    Text("attempt データがありません。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(detail.attempts.enumerated()), id: \.offset) { _, attempt in
                            attemptRow(attempt)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("詳細メトリクス (CER / attempt / provider など)")
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    private func attemptRow(_ attempt: BenchmarkSTTAttempt) -> some View {
        let durationText = "\(ms(Double(max(0, attempt.endedAtMs - attempt.startedAtMs))))ms"
        let errorText = attempt.error ?? "-"
        let errorColor: Color = attempt.error == nil ? .secondary : .red

        return HStack(spacing: 8) {
            Text(attempt.kind)
                .frame(width: 180, alignment: .leading)
            Text(attempt.status.rawValue)
                .frame(width: 80, alignment: .leading)
            Text(durationText)
                .frame(width: 90, alignment: .trailing)
            Text(errorText)
                .foregroundStyle(errorColor)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func fallbackSection(_ detail: BenchmarkCaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("データ不足")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            ForEach(detail.missingDataMessages, id: \.self) { message in
                Text("• \(message)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        }
    }

    private func metricChip(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    private func decimal(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.3f", value)
    }

    private func ms(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.1f", value)
    }
}
