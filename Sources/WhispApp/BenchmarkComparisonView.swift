import AppKit
import SwiftUI
import WhispCore

struct BenchmarkComparisonView: View {
    @ObservedObject var viewModel: BenchmarkViewModel
    let mode: BenchmarkComparisonMode
    private let judgeModels: [LLMModel] = [.gemini3FlashPreview, .gemini25FlashLite, .gpt4oMini, .gpt5Nano]

    private struct ComparisonColumn: Identifiable {
        let id: String
        let label: String
        let width: CGFloat
    }

    private struct PairwiseSummaryRow: Identifiable {
        let id: String
        let axis: String
        let a: Int
        let b: Int
        let tie: Int

        var total: Int { a + b + tie }
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if mode == .generationBattle {
                generationPairwiseBody
            } else {
                sttComparisonBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sttComparisonBody: some View {
        VStack(spacing: 0) {
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
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            if mode == .generationBattle {
                Picker("candidate A", selection: Binding(
                    get: { viewModel.generationPairCandidateAID ?? "" },
                    set: { viewModel.setGenerationPairCandidateA($0) }
                )) {
                    ForEach(viewModel.generationCandidates, id: \.id) { candidate in
                        Text(candidateDisplayLabel(candidate))
                            .lineLimit(1)
                            .help(candidate.id)
                            .tag(candidate.id)
                    }
                }
                .frame(width: 240)

                Picker("candidate B", selection: Binding(
                    get: { viewModel.generationPairCandidateBID ?? "" },
                    set: { viewModel.setGenerationPairCandidateB($0) }
                )) {
                    ForEach(viewModel.generationCandidates, id: \.id) { candidate in
                        Text(candidateDisplayLabel(candidate))
                            .lineLimit(1)
                            .help(candidate.id)
                            .tag(candidate.id)
                    }
                }
                .frame(width: 240)

                Picker("judge_model", selection: Binding(
                    get: { viewModel.generationPairJudgeModel },
                    set: { viewModel.setGenerationPairJudgeModel($0) }
                )) {
                    ForEach(judgeModels, id: \.self) { model in
                        Text(model.rawValue).tag(model)
                    }
                }
                .frame(width: 190)
            } else if mode == .generationSingle {
                Picker("candidate", selection: Binding(
                    get: { viewModel.selectedGenerationSingleCandidateID ?? "" },
                    set: { viewModel.setGenerationSingleCandidate($0) }
                )) {
                    ForEach(viewModel.generationCandidates, id: \.id) { candidate in
                        Text(candidateDisplayLabel(candidate))
                            .lineLimit(1)
                            .help(candidate.id)
                            .tag(candidate.id)
                    }
                }
                .frame(width: 280)
            } else {
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
            }

            Toggle("Force rerun", isOn: $viewModel.forceRerun)
                .toggleStyle(.switch)

            Button {
                switch mode {
                case .stt:
                    viewModel.runCompare()
                case .generationSingle:
                    viewModel.runGenerationSingleCompare()
                case .generationBattle:
                    viewModel.runGenerationBattleCompare()
                }
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
                Label("不備を再計算", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isExecutingBenchmark)

            if mode == .generationSingle || mode == .generationBattle {
                Button {
                    viewModel.openCreatePromptCandidateModal()
                } label: {
                    Label("新規Prompt Candidate", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isExecutingBenchmark)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var generationPairwiseBody: some View {
        VStack(spacing: 0) {
            generationSummary
            Divider()
            VStack(spacing: 0) {
                generationCaseList
                    .frame(minHeight: 430)
                Divider()
                generationCaseListBottomArea
            }
        }
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
            ForEach(comparisonColumns) { column in
                headerText(column.label, width: column.width)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func comparisonRow(_ row: BenchmarkComparisonRow) -> some View {
        HStack(spacing: 8) {
            ForEach(comparisonColumns) { column in
                let rendered = renderedValue(columnID: column.id, row: row)
                cellText(rendered.text, width: column.width, color: rendered.color)
            }
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
                    detailLine("candidate", candidateDisplayLabel(row.candidate))
                    detailLine("candidate_id", row.candidate.id)
                    detailLine("task", row.candidate.task.rawValue)
                    detailLine("model", row.candidate.model)
                    detailLine("prompt_name", row.candidate.promptName ?? "-")
                    detailLine("prompt_hash", row.candidate.generationPromptHash ?? "-")
                    detailLine("latest_run", row.latestRunID ?? "-")
                    detailLine("last_run_at", row.lastRunAt ?? "-")
                    if row.candidate.task == .generation {
                        Button {
                            viewModel.openEditPromptCandidateModal()
                        } label: {
                            Label("プロンプト編集", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.bordered)
                    }

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

            caseBreakdownHeader
                .padding(.horizontal, 12)

            List {
                ForEach(viewModel.caseBreakdownRows) { row in
                    Button {
                        viewModel.openCaseDetail(caseID: row.id)
                    } label: {
                        caseBreakdownRow(row)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }
            .listStyle(.plain)
        }
        .padding(.bottom, 8)
    }

    private var generationSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pairwise Summary")
                .font(.system(size: 13, weight: .semibold))
            if let summary = viewModel.generationPairwiseSummary {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        pairwiseCandidateChip("A", candidate: viewModel.generationPairCandidateA)
                        pairwiseCandidateChip("B", candidate: viewModel.generationPairCandidateB)
                        Spacer(minLength: 0)
                    }
                    pairwiseSummaryTable(summary)
                    Text("judge_model=\(viewModel.generationPairJudgeModel.rawValue)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("judged_cases=\(summary.judgedCases) / judge_error_cases=\(summary.judgeErrorCases)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("比較結果がありません。A/Bを選択して Run compare を実行してください。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var generationCaseList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Case List")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 8)

            HStack(spacing: 10) {
                headerText("case_id", width: 180)
                headerText("status", width: 70)
                headerText("overall_winner", width: 120)
                headerText("intent_winner", width: 110)
                headerText("hallucination_winner", width: 150)
                headerText("style_context_winner", width: 150)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)

            List(selection: Binding(
                get: { viewModel.selectedGenerationPairwiseCaseID },
                set: { viewModel.selectGenerationPairwiseCase($0) }
            )) {
                ForEach(viewModel.generationPairwiseCaseRows) { row in
                    HStack(spacing: 10) {
                        Text(row.id)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 180, alignment: .leading)
                        statusChip(row.status)
                            .frame(width: 70, alignment: .leading)
                        winnerCell(row.overallWinner, width: 120)
                        winnerCell(row.intentWinner, width: 110)
                        winnerCell(row.hallucinationWinner, width: 150)
                        winnerCell(row.styleContextWinner, width: 150)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.selectGenerationPairwiseCase(row.id)
                        viewModel.isPairwiseCaseDetailPresented = true
                    }
                    .tag(Optional(row.id))
                }
            }
            .listStyle(.plain)
        }
        .padding(.bottom, 8)
    }

    private var generationCaseListBottomArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Case Quick View")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let caseID = viewModel.selectedGenerationPairwiseCaseID {
                        Text("case_id: \(caseID)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                if let detail = viewModel.generationPairwiseCaseDetail {
                    HStack(spacing: 10) {
                        summaryChip("overall", text: winnerText(detail.overallWinner))
                        summaryChip("intent", text: winnerText(detail.intentWinner))
                        summaryChip("hallucination", text: winnerText(detail.hallucinationWinner))
                        summaryChip("style_context", text: winnerText(detail.styleContextWinner))
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("overall / intent / hallucination / style_context")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("overall: \(detail.overallReason ?? "-")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("intent: \(detail.intentReason ?? "-")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("hallucination: \(detail.hallucinationReason ?? "-")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("style_context: \(detail.styleContextReason ?? "-")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                } else if viewModel.selectedGenerationPairwiseCaseID != nil {
                    Text("詳細を読み込み中です。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                } else {
                    Text("左側のケースを選択してください。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }

            }
        }
    }

    private func summaryChip(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text(text)
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    private func summaryChip(_ title: String, a: Int, b: Int, tie: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text("A:\(a) B:\(b) tie:\(tie)")
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    private func pairwiseSummaryRows(_ summary: PairwiseRunSummary) -> [PairwiseSummaryRow] {
        [
            PairwiseSummaryRow(
                id: "overall",
                axis: "overall",
                a: summary.overallAWins,
                b: summary.overallBWins,
                tie: summary.overallTies
            ),
            PairwiseSummaryRow(
                id: "intent",
                axis: "intent",
                a: summary.intentAWins,
                b: summary.intentBWins,
                tie: summary.intentTies
            ),
            PairwiseSummaryRow(
                id: "hallucination",
                axis: "hallucination",
                a: summary.hallucinationAWins,
                b: summary.hallucinationBWins,
                tie: summary.hallucinationTies
            ),
            PairwiseSummaryRow(
                id: "style_context",
                axis: "style_context",
                a: summary.styleContextAWins,
                b: summary.styleContextBWins,
                tie: summary.styleContextTies
            ),
        ]
    }

    private func pairwiseSummaryTable(_ summary: PairwiseRunSummary) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                pairwiseSummaryHeaderCell("軸", width: 150)
                pairwiseSummaryHeaderCell("A", width: 110)
                pairwiseSummaryHeaderCell("B", width: 110)
                pairwiseSummaryHeaderCell("tie", width: 90)
                pairwiseSummaryHeaderCell("total", width: 90)
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ForEach(pairwiseSummaryRows(summary)) { row in
                HStack(spacing: 8) {
                    pairwiseSummaryCell(row.axis, width: 150)
                    pairwiseSummaryCountCell(row.a, row.total, width: 110)
                    pairwiseSummaryCountCell(row.b, row.total, width: 110)
                    pairwiseSummaryCountCell(row.tie, row.total, width: 90)
                    pairwiseSummaryCell(String(row.total), width: 90)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    private func pairwiseSummaryHeaderCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .frame(width: width, alignment: .leading)
    }

    private func pairwiseSummaryCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: width, alignment: .leading)
            .lineLimit(1)
    }

    private func pairwiseSummaryCountCell(_ count: Int, _ total: Int, width: CGFloat) -> some View {
        let detail = pairwiseCountText(count, total: total)
        return pairwiseSummaryCell(detail, width: width)
    }

    private func pairwiseCountText(_ count: Int, total: Int) -> String {
        guard total > 0 else { return String(count) }
        let rate = Double(count) / Double(total)
        return "\(count) (\(Int((rate * 100).rounded()))%)"
    }

    private func pairwiseCandidateChip(_ kind: String, candidate: BenchmarkCandidate?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kind)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            if let candidate {
                Text(candidateDisplayLabel(candidate))
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)
            } else {
                Text("-")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func winnerCell(_ winner: PairwiseWinner?, width: CGFloat) -> some View {
        Text(winnerText(winner))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(winnerColor(winner))
            .frame(width: width, alignment: .leading)
    }

    private func winnerText(_ winner: PairwiseWinner?) -> String {
        guard let winner else { return "-" }
        switch winner {
        case .a:
            return "A"
        case .b:
            return "B"
        case .tie:
            return "tie"
        }
    }

    private func winnerColor(_ winner: PairwiseWinner?) -> Color {
        switch winner {
        case .a:
            return .blue
        case .b:
            return .green
        case .tie:
            return .secondary
        case .none:
            return .secondary
        }
    }

    private func section(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var caseBreakdownHeader: some View {
        HStack(spacing: 10) {
            headerText("case_id", width: 180)
            headerText("status", width: 74)
            headerText("cer", width: 80)
            if isSttMode {
                headerText("stt_total_ms", width: 90)
                headerText("stt_after_stop_ms", width: 120)
            } else {
                headerText("post_ms", width: 90)
                headerText("intent_preservation", width: 110)
                headerText("hallucination_rate", width: 110)
            }
            Text("reason")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
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

    private var comparisonColumns: [ComparisonColumn] {
        switch mode {
        case .stt:
            var columns = [
                ComparisonColumn(id: "candidate_id", label: "candidate_id", width: 220),
                ComparisonColumn(id: "model", label: "model", width: 120),
                ComparisonColumn(id: "avg_cer", label: "avg_cer", width: 90),
                ComparisonColumn(id: "weighted_cer", label: "weighted_cer", width: 100),
                ComparisonColumn(id: "stt_after_stop_p50", label: "stt_after_stop_p50", width: 140),
                ComparisonColumn(id: "stt_after_stop_p95", label: "stt_after_stop_p95", width: 140),
                ComparisonColumn(id: "last_run_at", label: "last_run_at", width: 180),
            ]
            if shouldShowCaseCountColumns {
                columns.insert(ComparisonColumn(id: "executed_cases", label: "executed_cases", width: 110), at: 2)
                columns.insert(ComparisonColumn(id: "skip_cases", label: "skip_cases", width: 90), at: 3)
            }
            return columns
        case .generationSingle, .generationBattle:
            var columns = [
                ComparisonColumn(id: "candidate_id", label: "candidate", width: 320),
                ComparisonColumn(id: "model", label: "model", width: 120),
                ComparisonColumn(id: "prompt_name", label: "prompt_name", width: 120),
                ComparisonColumn(id: "avg_cer", label: "avg_cer", width: 90),
                ComparisonColumn(id: "weighted_cer", label: "weighted_cer", width: 100),
                ComparisonColumn(id: "post_ms_p95", label: "post_ms_p95", width: 100),
                ComparisonColumn(id: "intent_preservation", label: "intent_preservation", width: 140),
                ComparisonColumn(id: "hallucination_rate", label: "hallucination_rate", width: 130),
                ComparisonColumn(id: "last_run_at", label: "last_run_at", width: 180),
            ]
            if shouldShowCaseCountColumns {
                columns.insert(ComparisonColumn(id: "executed_cases", label: "executed_cases", width: 110), at: 3)
                columns.insert(ComparisonColumn(id: "skip_cases", label: "skip_cases", width: 90), at: 4)
            }
            return columns
        }
    }

    private var isSttMode: Bool {
        mode == .stt
    }

    private var shouldShowCaseCountColumns: Bool {
        let pairs = Set(viewModel.comparisonRows.map { "\($0.executedCases)-\($0.skipCases)" })
        return pairs.count > 1
    }

    private func renderedValue(columnID: String, row: BenchmarkComparisonRow) -> (text: String, color: Color) {
        switch columnID {
        case "candidate_id":
            if row.candidate.task == .generation {
                return (candidateDisplayLabel(row.candidate), .primary)
            }
            return (row.candidate.id, .primary)
        case "model":
            return (row.candidate.model, .primary)
        case "prompt_name":
            return (row.candidate.promptName ?? "-", .primary)
        case "executed_cases":
            return ("\(row.executedCases)", .primary)
        case "skip_cases":
            return ("\(row.skipCases)", .primary)
        case "avg_cer":
            return (decimal(row.avgCER), .primary)
        case "weighted_cer":
            return (decimal(row.weightedCER), .primary)
        case "stt_after_stop_p50":
            return (ms(row.sttAfterStopP50), .primary)
        case "stt_after_stop_p95":
            return (ms(row.sttAfterStopP95), .primary)
        case "post_ms_p95":
            return (ms(row.postMsP95), .primary)
        case "intent_preservation":
            return (decimal(row.intentPreservationScore), .primary)
        case "hallucination_rate":
            return (decimal(row.hallucinationRate), .primary)
        case "last_run_at":
            return (row.lastRunAt ?? "-", .primary)
        default:
            return ("-", .secondary)
        }
    }

    private func candidateDisplayLabel(_ candidate: BenchmarkCandidate) -> String {
        let promptName = (candidate.promptName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = promptName.isEmpty ? candidate.id : promptName
        return "\(displayName)（\(candidate.model)）#\(shortCandidateID(candidate.id))"
    }

    private func shortCandidateID(_ candidateID: String) -> String {
        let rawID = candidateID.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawID.isEmpty ? "-" : String(rawID.prefix(8))
    }

    @ViewBuilder
    private func caseBreakdownRow(_ row: BenchmarkCaseBreakdownRow) -> some View {
        HStack(spacing: 10) {
            Text(row.id)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 180, alignment: .leading)
            statusChip(row.status)
                .frame(width: 74, alignment: .leading)
            Text(decimal(row.cer))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 80, alignment: .trailing)

            if isSttMode {
                Text(ms(row.sttTotalMs))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 90, alignment: .trailing)
                Text(ms(row.sttAfterStopMs))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 120, alignment: .trailing)
            } else {
                Text(ms(row.postMs))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 90, alignment: .trailing)
                Text(decimal(row.intentPreservationScore))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 110, alignment: .trailing)
                Text(decimal(row.hallucinationRate))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 110, alignment: .trailing)
            }

            Text(row.reason ?? "-")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
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

struct BenchmarkGlobalModalOverlay: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissOnBackgroundTap()
                }

            if viewModel.isPromptCandidateModalPresented {
                BenchmarkOverlayModalCard(
                    minWidth: 760,
                    idealWidth: 820,
                    maxWidth: 920,
                    minHeight: 600,
                    maxHeight: 760
                ) {
                    BenchmarkPromptCandidateModal(viewModel: viewModel)
                }
            } else if viewModel.isPairwiseCaseDetailPresented {
                BenchmarkOverlayModalCard(
                    minWidth: 980,
                    idealWidth: 1080,
                    maxWidth: 1200,
                    minHeight: 720,
                    maxHeight: 820
                ) {
                    BenchmarkPairwiseCaseDetailModal(viewModel: viewModel)
                }
            } else if viewModel.isCaseDetailPresented {
                BenchmarkOverlayModalCard(
                    minWidth: 860,
                    idealWidth: 980,
                    maxWidth: 1080,
                    minHeight: 620,
                    maxHeight: 780
                ) {
                    BenchmarkCaseDetailModal(viewModel: viewModel)
                }
            } else if viewModel.isIntegrityCaseDetailPresented {
                BenchmarkOverlayModalCard(
                    minWidth: 920,
                    idealWidth: 980,
                    maxWidth: 1080,
                    minHeight: 620,
                    maxHeight: 780
                ) {
                    BenchmarkIntegrityCaseDetailModal(viewModel: viewModel)
                }
            }
        }
    }

    private func dismissOnBackgroundTap() {
        if viewModel.isPromptCandidateModalPresented {
            viewModel.dismissPromptCandidateModal()
            return
        }
        if viewModel.isPairwiseCaseDetailPresented {
            viewModel.dismissPairwiseCaseDetail()
            return
        }
        if viewModel.isCaseDetailPresented {
            viewModel.dismissCaseDetail()
            return
        }
        if viewModel.isIntegrityCaseDetailPresented {
            viewModel.dismissIntegrityCaseDetail()
        }
    }
}

private struct BenchmarkOverlayModalCard<Content: View>: View {
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let maxWidth: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let content: Content

    init(
        minWidth: CGFloat,
        idealWidth: CGFloat,
        maxWidth: CGFloat,
        minHeight: CGFloat,
        maxHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        content
            .frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth, minHeight: minHeight, maxHeight: maxHeight)
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

private struct BenchmarkPromptCandidateModal: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    private let models: [LLMModel] = [.gemini3FlashPreview, .gemini25FlashLite, .gpt4oMini, .gpt5Nano]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    groupBox {
                        row("candidate_id") {
                            Text(viewModel.promptCandidateDraftCandidateID)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        row("model") {
                            Picker("model", selection: $viewModel.promptCandidateDraftModel) {
                                ForEach(models, id: \.self) { model in
                                    Text(model.rawValue).tag(model)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 260)
                        }
                        row("prompt_name") {
                            TextField("例: concise", text: $viewModel.promptCandidateDraftName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }

                    groupBox {
                        Text("prompt_template")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $viewModel.promptCandidateDraftTemplate)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 260)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                            }
                    }

                    groupBox {
                        Text("利用可能な変数")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        ForEach(viewModel.promptVariableItems) { item in
                            variableRow(item)
                        }

                        Text("未取得データは空文字で置換されます。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    groupBox {
                        Toggle("require_context", isOn: $viewModel.promptCandidateDraftRequireContext)
                        Toggle("use_cache", isOn: $viewModel.promptCandidateDraftUseCache)
                    }

                    if !viewModel.promptCandidateDraftValidationError.isEmpty {
                        Text(viewModel.promptCandidateDraftValidationError)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }

            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Text(viewModel.isPromptCandidateEditing ? "Prompt Candidate編集" : "Prompt Candidate新規作成")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("閉じる") {
                viewModel.dismissPromptCandidateModal()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("キャンセル") {
                viewModel.dismissPromptCandidateModal()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("保存") {
                viewModel.savePromptCandidateModal()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func groupBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    private func variableRow(_ item: PromptVariableItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.token)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(item.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("例: \(item.sample)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("挿入") {
                viewModel.appendPromptVariableToDraft(item.token)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct BenchmarkPairwiseCaseDetailModal: View {
    @ObservedObject var viewModel: BenchmarkViewModel
    @State private var selectedPairwiseTab: PairwiseCaseDetailTab = .output
    @State private var selectedJudgeTab: PairwiseJudgeTab = .round1
    @State private var outputPromptBlockHeight: CGFloat = 0

    private enum PairwiseCaseDetailTab: Hashable {
        case output
        case judge
    }

    private enum PairwiseJudgeTab: Hashable {
        case round1
        case round2
        case overall
    }

    init(viewModel: BenchmarkViewModel, startsInJudgeTab: Bool = false) {
        self.viewModel = viewModel
        _selectedPairwiseTab = State(initialValue: startsInJudgeTab ? .judge : .output)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let detail = viewModel.generationPairwiseCaseDetail {
                modalHeader(detail)
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("表示", selection: $selectedPairwiseTab) {
                            Text("出力").tag(PairwiseCaseDetailTab.output)
                            Text("評価").tag(PairwiseCaseDetailTab.judge)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 180)
                        .padding(.horizontal, 12)

                        switch selectedPairwiseTab {
                        case .output:
                            outputComparisonTab(detail)
                        case .judge:
                            judgeComparisonTab(detail)
                        }
                    }
                    .padding(12)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ケース詳細がありません。")
                        .font(.system(size: 14, weight: .semibold))
                    Text("ケース行を選択して再試行してください。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            }

            Divider()
            HStack {
                Spacer()
                Button("閉じる") {
                    viewModel.dismissPairwiseCaseDetail()
                }
                .buttonStyle(.bordered)
                .padding(.trailing, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private func modalHeader(_ detail: BenchmarkPairwiseCaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Generation対戦 ケース詳細")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                copyableCaseIDChip(detail.caseID)
                pairwiseStatusBadge(detail.status)
            }
            HStack(spacing: 8) {
                verdictChip("overall", winnerText(detail.overallWinner))
                verdictChip("intent", winnerText(detail.intentWinner))
                verdictChip("hallucination", winnerText(detail.hallucinationWinner))
                verdictChip("style_context", winnerText(detail.styleContextWinner))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func candidateDisplayLabel(_ candidate: BenchmarkCandidate) -> String {
        let promptName = (candidate.promptName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = promptName.isEmpty ? candidate.id : promptName
        return "\(displayName)（\(candidate.model)）#\(shortCandidateID(candidate.id))"
    }

    private func shortCandidateID(_ candidateID: String) -> String {
        let rawID = candidateID.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawID.isEmpty ? "-" : String(rawID.prefix(8))
    }

    private func outputComparisonTab(_ detail: BenchmarkPairwiseCaseDetail) -> some View {
        let promptMinHeight = outputPromptBlockHeight > 0 ? outputPromptBlockHeight : nil
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("出力")
            labeledTextBlock(label: "STT入力（共通）", text: detail.sttText)
            splitOutputColumns(
                left: outputPanel(
                    kind: "A",
                    model: viewModel.generationPairCandidateA?.model,
                    prompt: detail.promptA,
                    output: detail.outputA,
                    promptHeightID: "output_prompt_a",
                    promptMinHeight: promptMinHeight
                ),
                right: outputPanel(
                    kind: "B",
                    model: viewModel.generationPairCandidateB?.model,
                    prompt: detail.promptB,
                    output: detail.outputB,
                    promptHeightID: "output_prompt_b",
                    promptMinHeight: promptMinHeight
                )
            )
        }
        .padding(12)
        .onPreferenceChange(PairwiseBlockHeightPreferenceKey.self) { heights in
            let maxHeight = max(
                heights["output_prompt_a"] ?? 0,
                heights["output_prompt_b"] ?? 0
            )
            guard maxHeight > 0 else { return }
            if abs(maxHeight - outputPromptBlockHeight) > 0.5 {
                outputPromptBlockHeight = maxHeight
            }
        }
    }

    private func judgeComparisonTab(_ detail: BenchmarkPairwiseCaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("判定")
            HStack(spacing: 6) {
                Text("Judge Model")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(viewModel.generationPairJudgeModel.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 2)

            judgeInputImageSection(detail)

            Picker("judge_view", selection: $selectedJudgeTab) {
                Text("1件目:プロンプト/応答").tag(PairwiseJudgeTab.round1)
                Text("2件目:プロンプト/応答").tag(PairwiseJudgeTab.round2)
                Text("全体:判定結果").tag(PairwiseJudgeTab.overall)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)

            switch selectedJudgeTab {
            case .round1:
                judgeRoundSection(
                    title: "1件目",
                    prompt: detail.promptPairwiseRound1,
                    response: detail.judgeResponseRound1
                )
            case .round2:
                judgeRoundSection(
                    title: "2件目",
                    prompt: detail.promptPairwiseRound2,
                    response: detail.judgeResponseRound2
                )
            case .overall:
                VStack(spacing: 8) {
                    labeledTextBlock(label: "judge決定JSON", text: detail.judgeDecisionJSON)
                    labeledTextBlock(
                        label: "判定結果",
                        text: "overall: \(winnerText(detail.overallWinner)) / intent: \(winnerText(detail.intentWinner)) / hallucination: \(winnerText(detail.hallucinationWinner)) / style_context: \(winnerText(detail.styleContextWinner))"
                    )
                }
            }

            if let judgeError = detail.judgeError, !judgeError.isEmpty {
                labeledTextBlock(label: "judge_error", text: judgeError)
            }
        }
        .padding(12)
    }

    private func judgeInputImageSection(_ detail: BenchmarkPairwiseCaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            blockLabel("judge入力スクリーンショット")
            if let image = judgeInputImage(path: detail.judgeInputImagePath) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 280)
                    .background(Color(NSColor.windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    }
            } else {
                textValueBlock(
                    text: detail.judgeInputImageMissingReason ?? "judge入力画像はありません"
                )
            }
            if let path = detail.judgeInputImagePath {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .padding(.horizontal, 2)
            }
        }
    }

    private func judgeInputImage(path: String?) -> NSImage? {
        let trimmed = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              FileManager.default.fileExists(atPath: trimmed)
        else {
            return nil
        }
        return NSImage(contentsOfFile: trimmed)
    }

    private func judgeRoundSection(title: String, prompt: String, response: String) -> some View {
        VStack(spacing: 8) {
            labeledTextBlock(label: "\(title)の比較プロンプト", text: prompt)
            labeledTextBlock(label: "\(title)のjudge応答", text: response)
        }
    }

    private func outputPanel(
        kind: String,
        model: String?,
        prompt: String,
        output: String,
        promptHeightID: String,
        promptMinHeight: CGFloat?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            modelLine(kind: kind, model: model)
            labeledTextBlock(
                label: "\(kind) プロンプト",
                text: prompt,
                minHeight: promptMinHeight,
                heightID: promptHeightID
            )
            labeledTextBlock(label: "\(kind) 整形結果", text: output)
        }
    }

    private func splitOutputColumns<Left: View, Right: View>(
        left: Left,
        right: Right
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            left
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Divider()
                .padding(.horizontal, 10)
            right
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func modelLine(kind: String, model: String?) -> some View {
        HStack(spacing: 6) {
            Text("\(kind) Model")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text((model ?? "-").isEmpty ? "-" : (model ?? "-"))
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 2)
    }

    private func copyableCaseIDChip(_ caseID: String) -> some View {
        Button {
            copyToClipboard(caseID)
        } label: {
            HStack(spacing: 5) {
                Text("case_id")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                Text(shortCaseID(caseID))
                    .font(.system(size: 10, design: .monospaced))
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("クリックで case_id をコピー\n\(caseID)")
    }

    private func pairwiseStatusBadge(_ status: BenchmarkCaseStatus) -> some View {
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func shortCaseID(_ caseID: String) -> String {
        let trimmed = caseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-" }
        if trimmed.count <= 20 {
            return trimmed
        }
        return "\(trimmed.prefix(10))...\(trimmed.suffix(6))"
    }

    private func copyToClipboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private func labeledTextBlock(
        label: String,
        text: String,
        minHeight: CGFloat? = nil,
        heightID: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            blockLabel(label)
            textValueBlock(text: text, minHeight: minHeight, heightID: heightID)
        }
    }

    private func blockLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
    }

    private func textValueBlock(
        text: String,
        minHeight: CGFloat? = nil,
        heightID: String? = nil
    ) -> some View {
        Text(text.isEmpty ? "-" : text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(text.isEmpty ? .secondary : .primary)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: minHeight, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
        .background {
            if let heightID {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PairwiseBlockHeightPreferenceKey.self,
                        value: [heightID: proxy.size.height]
                    )
                }
            }
        }
    }

    private func verdictChip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func textBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(text == "-" ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 92)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func pairwiseComparisonColumns(
        leftTitle: String,
        leftText: String,
        centerTitle: String,
        centerText: String,
        rightTitle: String,
        rightText: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            pairwiseTextColumn(title: leftTitle, text: leftText)
            pairwiseTextColumn(title: centerTitle, text: centerText)
            pairwiseTextColumn(title: rightTitle, text: rightText)
        }
    }

    private func pairwiseTextColumn(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text.isEmpty ? "-" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 92)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func winnerText(_ winner: PairwiseWinner?) -> String {
        guard let winner else { return "-" }
        switch winner {
        case .a:
            return "A"
        case .b:
            return "B"
        case .tie:
            return "tie"
        }
    }
}

private struct PairwiseBlockHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        for (key, height) in nextValue() {
            value[key] = max(value[key] ?? 0, height)
        }
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
