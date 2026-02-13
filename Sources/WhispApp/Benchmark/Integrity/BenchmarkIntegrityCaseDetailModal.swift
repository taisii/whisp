import AppKit
import SwiftUI

struct BenchmarkIntegrityCaseDetailModal: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let detail = viewModel.selectedIntegrityCaseDetail {
                header(detail)
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        audioSection(detail)
                        transcriptsSection(detail)
                        outputSection(detail)
                        captureSection(detail)
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 8) {
                    Text("ケース詳細がありません")
                        .font(.system(size: 14, weight: .semibold))
                    Text("一覧からケースを選択してください。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footer
        }
    }

    private func header(_ detail: BenchmarkIntegrityCaseDetail) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Integrity Case Detail")
                    .font(.system(size: 16, weight: .semibold))
                Text("case_id: \(detail.id)")
                    .font(.system(size: 11, design: .monospaced))
            }
            Spacer(minLength: 0)
            statusBadge(detail.status)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func audioSection(_ detail: BenchmarkIntegrityCaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("音声")
            HStack(spacing: 10) {
                Button {
                    viewModel.toggleCaseAudioPlayback()
                } label: {
                    Label(
                        viewModel.isCaseAudioPlaying ? "停止" : "再生",
                        systemImage: viewModel.isCaseAudioPlaying ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)

                Text(detail.audioFilePath ?? "音声ファイルがありません")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
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

    private func transcriptsSection(_ detail: BenchmarkIntegrityCaseDetail) -> some View {
        HStack(alignment: .top, spacing: 12) {
            editableTextPane(
                title: "STT入力",
                text: viewModel.isIntegrityCaseEditing ? $viewModel.integrityCaseDraftSTTText : .constant(detail.sttText),
                editable: viewModel.isIntegrityCaseEditing
            )
            editableTextPane(
                title: "期待される出力",
                text: viewModel.isIntegrityCaseEditing ? $viewModel.integrityCaseDraftGroundTruthText : .constant(detail.groundTruthText),
                editable: viewModel.isIntegrityCaseEditing
            )
        }
    }

    private func outputSection(_ detail: BenchmarkIntegrityCaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("output_text (閲覧専用)")
            readOnlyText(detail.outputText)
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    private func captureSection(_ detail: BenchmarkIntegrityCaseDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("画像キャプチャ")
            if let image = loadImage(path: detail.visionImageFilePath) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 280)
                    .background(Color(NSColor.windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    }
            } else {
                readOnlyText("画像キャプチャはありません")
            }
            if let path = detail.visionImageFilePath {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
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

    private var footer: some View {
        VStack(spacing: 10) {
            if viewModel.isIntegrityCaseDeleteConfirmationPresented {
                HStack(spacing: 10) {
                    Text("このケースを削除します。よろしいですか？")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("キャンセル") {
                        viewModel.cancelIntegrityCaseDelete()
                    }
                    .buttonStyle(.bordered)
                    Button("削除する") {
                        viewModel.confirmIntegrityCaseDelete()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }

            HStack(spacing: 8) {
                Button("削除") {
                    viewModel.requestIntegrityCaseDelete()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.selectedIntegrityCaseDetail == nil)

                Spacer()

                if viewModel.isIntegrityCaseEditing {
                    Button("キャンセル") {
                        viewModel.cancelIntegrityCaseEditing()
                    }
                    .buttonStyle(.bordered)

                    Button("保存") {
                        viewModel.saveIntegrityCaseEdits()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("編集") {
                        viewModel.beginIntegrityCaseEditing()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.selectedIntegrityCaseDetail == nil)
                }

                Button("閉じる") {
                    viewModel.dismissIntegrityCaseDetail()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func editableTextPane(title: String, text: Binding<String>, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(title)
            if editable {
                TextEditor(text: text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 160)
                    .padding(6)
                    .background(Color(NSColor.windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    }
            } else {
                readOnlyText(text.wrappedValue)
            }
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

    private func readOnlyText(_ text: String) -> some View {
        ScrollView {
            Text(text.isEmpty ? "未設定" : text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(minHeight: 120)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
    }

    private func statusBadge(_ status: BenchmarkIntegrityStatusBadge) -> some View {
        let style = statusStyle(status)
        return Text(style.text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(style.color.opacity(0.16))
            .foregroundStyle(style.color)
            .clipShape(Capsule())
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

    private func loadImage(path: String?) -> NSImage? {
        let trimmed = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) else {
            return nil
        }
        return NSImage(contentsOfFile: trimmed)
    }
}
