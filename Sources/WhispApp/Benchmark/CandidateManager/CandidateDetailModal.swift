import SwiftUI

struct CandidateDetailModal: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CandidateFormFields(
                        candidateID: $viewModel.promptCandidateDraftCandidateID,
                        model: $viewModel.promptCandidateDraftModel,
                        promptName: $viewModel.promptCandidateDraftName,
                        promptTemplate: $viewModel.promptCandidateDraftTemplate,
                        requireContext: $viewModel.promptCandidateDraftRequireContext,
                        useCache: $viewModel.promptCandidateDraftUseCache,
                        variableItems: viewModel.promptVariableItems,
                        editable: viewModel.isCandidateDetailEditable,
                        onAppendVariable: { token in
                            viewModel.appendPromptVariableToDraft(token)
                        }
                    )

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
        .alert("候補を削除しますか？", isPresented: $viewModel.isCandidateDeleteConfirmationPresented) {
            Button("削除", role: .destructive) {
                viewModel.deleteCandidateFromDetail()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("削除後もベンチマーク結果は保持されます。")
        }
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("閉じる") {
                viewModel.dismissCandidateDetailModal()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if viewModel.isCandidateDetailEditable {
                Button("キャンセル") {
                    viewModel.cancelCandidateDetailEditing()
                }
                .buttonStyle(.bordered)

                if viewModel.canDeleteCandidateInDetail {
                    Button("削除", role: .destructive) {
                        viewModel.requestCandidateDeleteConfirmation()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("保存") {
                    viewModel.saveCandidateDetailModal()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("編集") {
                    viewModel.beginCandidateDetailEditing()
                }
                .buttonStyle(.bordered)

                Button("削除", role: .destructive) {
                    viewModel.requestCandidateDeleteConfirmation()
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var title: String {
        switch viewModel.candidateDetailModalMode {
        case .view:
            return "候補詳細"
        case .edit:
            return "候補編集"
        case .create:
            return "候補追加"
        }
    }
}
