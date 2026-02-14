import SwiftUI

struct BenchmarkIntegrityView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.integrityCaseRows.isEmpty {
                VStack(spacing: 8) {
                    Text("表示できるケースがありません")
                        .font(.system(size: 14, weight: .semibold))
                    Text("manual_test_cases.jsonl が空か、まだ作成されていません。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.integrityCaseRows) { row in
                                caseRow(row)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(rowBackground(row))
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            caseIDBadge(row)
                .frame(width: 240, alignment: .leading)

            Button {
                viewModel.openIntegrityCaseDetail(caseID: row.id)
            } label: {
                HStack(spacing: 10) {
                    cellText(row.sttPreview, width: 420)
                    cellText(row.referencePreview, width: 420)
                    statusBadge(row)
                        .frame(width: 170, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func caseIDBadge(_ row: BenchmarkIntegrityCaseRow) -> some View {
        Button {
            viewModel.copyIntegrityCaseID(row.id)
        } label: {
            Text(row.id)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(row.isMissingInDataset ? Color.orange : Color.primary)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("case_id をコピー")
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
