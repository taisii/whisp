import AppKit
import SwiftUI
import WhispCore

struct DebugView: View {
    @ObservedObject var viewModel: DebugViewModel
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                leftPane
                Divider()
                rightPane
            }
            Divider()
            statusBar
        }
        .onAppear {
            viewModel.refresh()
        }
        .alert("このデバッグログを削除しますか？", isPresented: $showingDeleteConfirmation) {
            Button("削除", role: .destructive) {
                viewModel.deleteSelectedCapture()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は元に戻せません。")
        }
        .frame(minWidth: 1180, minHeight: 760)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Debug Lab")
                    .font(.system(size: 18, weight: .semibold))
                Text("録音1件の評価データを、音声・画像・STT・LLM・正解で検証する")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            iconButton(symbol: "arrow.clockwise", helpText: "再読み込み") {
                viewModel.refresh()
            }

            Text("表示件数: \(viewModel.visibleCountText)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var leftPane: some View {
        VStack(spacing: 12) {
            Picker("タブ", selection: $viewModel.recordFilter) {
                ForEach(DebugRecordFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            List(selection: $viewModel.selectedCaptureID) {
                ForEach(viewModel.filteredRecords) { record in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.id)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Text(record.createdAt)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(record.llmModel)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        VStack(alignment: .trailing, spacing: 6) {
                            statusBadge(text: record.status)
                            HStack(spacing: 6) {
                                if record.context != nil {
                                    Image(systemName: "rectangle.3.group.bubble.left")
                                        .foregroundStyle(.secondary)
                                }
                                if record.accessibilitySnapshot != nil {
                                    Image(systemName: "accessibility")
                                        .foregroundStyle(.secondary)
                                }
                                if record.visionImageFilePath != nil {
                                    Image(systemName: "photo")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.system(size: 11))
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(record.id)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(minWidth: 320, maxWidth: 360)
        .onChange(of: viewModel.recordFilter) { _, _ in
            viewModel.handleFilterChanged()
        }
        .onChange(of: viewModel.selectedCaptureID) { _, newValue in
            viewModel.select(captureID: newValue)
        }
    }

    private var rightPane: some View {
        Group {
            if let details = viewModel.details {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        overviewSection(details: details)
                        mediaSection(details: details)
                        textComparisonSection(details: details)
                        groundTruthSection
                        promptSection(details: details)
                    }
                    .padding(16)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("データがありません")
                        .font(.system(size: 14, weight: .semibold))
                    Text("左の一覧から録音データを選択してください。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func overviewSection(details: DebugCaptureDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Overview")
                .font(.system(size: 14, weight: .semibold))

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("run_id: \(details.record.runID)")
                    Text("status: \(details.record.status)")
                    Text("model: \(details.record.llmModel)")
                    Text("sample_rate: \(details.record.sampleRate)")
                    Text("app: \(details.record.appName ?? "-")")
                    Text("run_dir: \(details.record.runDirectoryPath)")
                    Text("events: \(details.record.eventsFilePath)")
                    if let error = details.record.errorMessage, !error.isEmpty {
                        Text("error: \(error)")
                            .foregroundStyle(.red)
                    }
                }
                .font(.system(size: 12, design: .monospaced))

                Spacer()

                HStack(spacing: 8) {
                    iconButton(
                        symbol: viewModel.isAudioPlaying ? "stop.fill" : "play.fill",
                        helpText: viewModel.isAudioPlaying ? "録音を停止" : "録音を再生"
                    ) {
                        viewModel.toggleAudioPlayback()
                    }
                    iconButton(symbol: "folder", helpText: "録音ファイルを表示") {
                        viewModel.revealAudioFile()
                    }
                    iconButton(symbol: "folder.fill", helpText: "runフォルダを開く") {
                        viewModel.revealRunDirectory()
                    }
                    iconButton(symbol: "list.bullet.rectangle.portrait", helpText: "events.jsonl を表示") {
                        viewModel.revealEventsFile()
                    }
                    iconButton(symbol: "photo", helpText: "画像ファイルを表示", disabled: (details.record.visionImageFilePath == nil)) {
                        viewModel.revealVisionImageFile()
                    }
                    iconButton(symbol: "text.quote", helpText: "Prompt保存先を開く") {
                        viewModel.openPromptsDirectory()
                    }
                    iconButton(symbol: "trash", helpText: "削除", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }
            }
        }
        .cardStyle()
    }

    private func mediaSection(details: DebugCaptureDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Media")
                .font(.system(size: 14, weight: .semibold))

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Audio")
                        .font(.system(size: 13, weight: .semibold))
                    Text(details.record.audioFilePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Vision Image")
                        .font(.system(size: 13, weight: .semibold))
                    if let image = visionImage(from: details.record.visionImageFilePath) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 360, minHeight: 180, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                            }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                            Text("画像なし")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 360, minHeight: 180, maxHeight: 220)
                        .frame(maxWidth: .infinity)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let context = details.record.context, !context.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Context")
                        .font(.system(size: 12, weight: .semibold))
                    if let summary = context.visionSummary, !summary.isEmpty {
                        Text("summary: \(summary)")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    if !context.visionTerms.isEmpty {
                        Text("terms: \(context.visionTerms.joined(separator: ", "))")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    if let accessibilityText = context.accessibilityText, !accessibilityText.isEmpty {
                        Text("accessibility: \(accessibilityText)")
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            if let accessibility = details.record.accessibilitySnapshot {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accessibility Snapshot")
                        .font(.system(size: 12, weight: .semibold))
                    Text("trusted: \(accessibility.trusted ? "true" : "false")")
                    Text("bundle: \(accessibility.bundleID ?? "-")")
                    Text("window: \(accessibility.windowTitle ?? "-")")
                    Text("role: \(accessibility.focusedElement?.role ?? "-")")
                    Text("placeholder: \(accessibility.focusedElement?.placeholder ?? "-")")
                    Text("selected: \(accessibility.focusedElement?.selectedText ?? "-")")
                    Text("caret_context: \(accessibility.focusedElement?.caretContext ?? "-")")
                    if let error = accessibility.error, !error.isEmpty {
                        Text("error: \(error)")
                            .foregroundStyle(.red)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
        .cardStyle()
    }

    private func textComparisonSection(details: DebugCaptureDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Texts")
                .font(.system(size: 14, weight: .semibold))

            textPane(
                title: "STT出力",
                text: details.record.sttText ?? "",
                iconSymbol: "doc.on.doc",
                iconHelp: "STT出力をコピー",
                iconAction: {
                    viewModel.copySTTText()
                }
            )

            textPane(
                title: "LLM出力",
                text: details.record.outputText ?? "",
                iconSymbol: "doc.on.doc.fill",
                iconHelp: "LLM出力をコピー",
                iconAction: {
                    viewModel.copyOutputText()
                }
            )
        }
        .cardStyle()
    }

    private func textPane(
        title: String,
        text: String,
        iconSymbol: String,
        iconHelp: String,
        iconAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                iconButton(symbol: iconSymbol, helpText: iconHelp, action: iconAction)
            }

            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            }
            .frame(minHeight: 110)
        }
    }

    private var groundTruthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("正解テキスト")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: viewModel.hasUnsavedGroundTruthChanges ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(viewModel.hasUnsavedGroundTruthChanges ? Color.orange : Color.green)
            }

            TextEditor(text: $viewModel.groundTruthDraft)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                }

            HStack(spacing: 8) {
                iconButton(symbol: "arrow.down.doc", helpText: "LLM出力を正解欄に反映") {
                    viewModel.applyOutputAsGroundTruth()
                }
                iconButton(symbol: "doc.on.doc", helpText: "正解テキストをコピー") {
                    viewModel.copyGroundTruth()
                }
                iconButton(symbol: "clipboard", helpText: "正解テキストを貼り付け") {
                    viewModel.pasteGroundTruth()
                }
                iconButton(symbol: "square.and.arrow.down.fill", helpText: "正解を保存") {
                    viewModel.saveGroundTruth()
                }
                iconButton(symbol: "plus.square.on.square", helpText: "テストケースに追加") {
                    viewModel.appendManualTestCase()
                }
            }

            if !viewModel.groundTruthSaveMessage.isEmpty {
                Text(viewModel.groundTruthSaveMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(viewModel.groundTruthSaveIsError ? Color.red : Color.secondary)
            }
        }
        .cardStyle()
    }

    private func promptSection(details: DebugCaptureDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("送信プロンプト")
                .font(.system(size: 14, weight: .semibold))

            if details.prompts.isEmpty {
                Text("このrun_idに紐づくプロンプトはまだ保存されていません。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Picker("prompt", selection: $viewModel.selectedPromptIndex) {
                    ForEach(Array(details.prompts.enumerated()), id: \.offset) { index, prompt in
                        Text("\(prompt.stage) / \(prompt.model)").tag(index)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if let prompt = viewModel.selectedPrompt {
                    Text("chars: \(prompt.promptChars) / context terms: \(prompt.contextTermsCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(prompt.promptText)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    }
                    .frame(minHeight: 180)
                }
            }
        }
        .cardStyle()
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(viewModel.statusIsError ? Color.orange : Color.secondary)
            Text(viewModel.statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(viewModel.statusIsError ? Color.red : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func iconButton(
        symbol: String,
        helpText: String,
        role: ButtonRole? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Group {
            if let role {
                Button(role: role, action: action) {
                    Label(helpText, systemImage: symbol)
                        .labelStyle(.iconOnly)
                }
            } else {
                Button(action: action) {
                    Label(helpText, systemImage: symbol)
                        .labelStyle(.iconOnly)
                }
            }
        }
        .buttonStyle(.bordered)
        .help(helpText)
        .disabled(disabled)
    }

    private func statusBadge(text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(Capsule())
    }

    private func visionImage(from path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        return NSImage(contentsOfFile: path)
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
