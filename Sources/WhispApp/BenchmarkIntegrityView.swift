import SwiftUI
import WhispCore

struct BenchmarkIntegrityView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            if viewModel.integrityCaseRows.isEmpty {
                VStack(spacing: 8) {
                    Text("表示できるケースがありません")
                        .font(.system(size: 14, weight: .semibold))
                    Text("manual_test_cases.jsonl が空か、まだ作成されていません。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button {
                        viewModel.scanIntegrity()
                    } label: {
                        Label("不備を再計算", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isExecutingBenchmark)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.integrityCaseRows) { row in
                                Button {
                                    viewModel.openIntegrityCaseDetail(caseID: row.id)
                                } label: {
                                    caseRow(row)
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(rowBackground(row))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Task", selection: $viewModel.selectedTask) {
                Text("STT").tag(BenchmarkKind.stt)
                Text("Generation").tag(BenchmarkKind.generation)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Button {
                viewModel.scanIntegrity()
            } label: {
                Label("不備を再計算", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isExecutingBenchmark)

            Button("Copy case_id") {
                viewModel.copySelectedIssueCaseID()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.selectedIntegrityCaseID == nil)

            Button("Open related run dir") {
                viewModel.openRelatedRunDirectory()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.selectedIntegrityCaseID == nil)

            Button(viewModel.selectedIntegrityCaseExclusionLabel) {
                viewModel.toggleSelectedIntegrityCaseExclusion()
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canToggleSelectedIntegrityCaseExclusion)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            headerText("case_id", width: 240)
            headerText("stt_text", width: 420)
            headerText("reference", width: 420)
            headerText("status", width: 170)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func caseRow(_ row: BenchmarkIntegrityCaseRow) -> some View {
        HStack(spacing: 10) {
            cellText(row.id, width: 240, color: row.isMissingInDataset ? .orange : .primary)
            cellText(row.sttPreview, width: 420)
            cellText(row.referencePreview, width: 420)
            statusBadge(row)
                .frame(width: 170, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    @ViewBuilder
    private func rowBackground(_ row: BenchmarkIntegrityCaseRow) -> some View {
        if row.status == .issue {
            Color.red.opacity(0.12)
        } else if row.status == .excluded || row.status == .datasetMissing {
            Color.orange.opacity(0.12)
        } else {
            Color.clear
        }
    }

    private func headerText(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
            .lineLimit(1)
    }

    private func cellText(_ text: String, width: CGFloat, color: Color = .primary) -> some View {
        Text(text)
            .foregroundStyle(color)
            .frame(width: width, alignment: .leading)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func statusBadge(_ row: BenchmarkIntegrityCaseRow) -> some View {
        let style = statusStyle(row.status)
        return HStack(spacing: 6) {
            Text(style.text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(style.color.opacity(0.16))
                .foregroundStyle(style.color)
                .clipShape(Capsule())
            Text("\(row.activeIssueCount)/\(row.issueCount)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func statusStyle(_ status: BenchmarkIntegrityStatusBadge) -> (text: String, color: Color) {
        switch status {
        case .ok:
            return ("OK", .green)
        case .issue:
            return ("ISSUE", .red)
        case .excluded:
            return ("EXCLUDED", .orange)
        case .datasetMissing:
            return ("DATASET_MISSING", .orange)
        }
    }
}
