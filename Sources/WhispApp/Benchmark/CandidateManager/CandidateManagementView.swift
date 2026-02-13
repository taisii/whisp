import SwiftUI

struct CandidateManagementView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            tableHeader
            Divider()
            candidateList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            Text("Generation 候補管理")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                viewModel.openCreateCandidateDetailModal()
            } label: {
                Label("候補追加", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            headerCell("Model", width: 280)
            headerCell("タグ", width: 320)
            headerCell("勝率", width: 120, alignment: .trailing)
            headerCell("W-L-T", width: 120, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var candidateList: some View {
        List(selection: Binding(
            get: { viewModel.selectedCandidateManagementID },
            set: { viewModel.selectedCandidateManagementID = $0 }
        )) {
            ForEach(viewModel.candidateManagementRows) { row in
                Button {
                    viewModel.openCandidateDetailModal(candidateID: row.candidate.id)
                } label: {
                    HStack(spacing: 12) {
                        cellText(row.candidate.model, width: 280)
                        cellText((row.candidate.promptName ?? row.candidate.id), width: 320)
                        cellText(winRateText(row.winRate), width: 120, alignment: .trailing)
                        cellText("\(row.wins)-\(row.losses)-\(row.ties)", width: 120, alignment: .trailing)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(Optional(row.id))
            }
        }
        .listStyle(.plain)
    }

    private func headerCell(_ text: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .frame(width: width, alignment: alignment)
    }

    private func cellText(_ text: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private func winRateText(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.1f%%", value * 100)
    }
}
