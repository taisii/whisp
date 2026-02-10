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
                            Text(shortID(record.id))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .help(record.id)
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
                        topSummarySection(details: details)
                        artifactsSection(details: details)
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

    private func topSummarySection(details: DebugCaptureDetails) -> some View {
        let record = details.record
        let analysis = viewModel.selectedEventAnalysis
        let sttInfo = analysis.sttInfo
        let accessibility = record.accessibilitySnapshot
        let focusedElement = accessibility?.focusedElement

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Summary")
                    .font(.system(size: 14, weight: .semibold))
                statusBadge(text: record.status)
                Spacer()
                copyableIDChip(
                    label: "capture",
                    value: record.id,
                    copyMessage: "capture_id をコピー"
                ) {
                    viewModel.copyCaptureID()
                }
                copyableIDChip(
                    label: "run",
                    value: record.runID,
                    copyMessage: "run_id をコピー"
                ) {
                    viewModel.copyRunID()
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("使ったモデル")
                        .font(.system(size: 13, weight: .semibold))
                    labeledMetric(name: "STT", value: sttInfo.providerName)
                    labeledMetric(name: "STT方式", value: sttInfo.routeName)
                    labeledMetric(name: "整形", value: record.llmModel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .innerCardStyle()

                VStack(alignment: .leading, spacing: 6) {
                    Text("とってこれた情報")
                        .font(.system(size: 13, weight: .semibold))
                    availabilitySection(title: "Vision", rows: [
                        ("Vision画像", hasText(record.visionImageFilePath)),
                        ("Vision MIMEタイプ", hasText(record.visionImageMimeType)),
                    ])

                    availabilitySection(title: "Accessibility", rows: [
                        ("Snapshot", accessibility != nil),
                        ("アクセシビリティ許可", accessibility?.trusted == true),
                        ("取得時刻", hasText(accessibility?.capturedAt)),
                        ("前面アプリ名", hasText(accessibility?.appName)),
                        ("Bundle ID", hasText(accessibility?.bundleID)),
                        ("Process ID", accessibility?.processID != nil),
                        ("Window Title", hasText(accessibility?.windowTitle)),
                        ("Window Text", hasText(accessibility?.windowText)),
                        ("エラー情報", hasText(accessibility?.error)),
                    ])

                    availabilitySection(title: "Focused Element", rows: [
                        ("フォーカス要素", focusedElement != nil),
                        ("Role", hasText(focusedElement?.role)),
                        ("Subrole", hasText(focusedElement?.subrole)),
                        ("Title", hasText(focusedElement?.title)),
                        ("Description", hasText(focusedElement?.elementDescription)),
                        ("Help", hasText(focusedElement?.help)),
                        ("Placeholder", hasText(focusedElement?.placeholder)),
                        ("Value", hasText(focusedElement?.value)),
                        ("選択テキスト", hasText(focusedElement?.selectedText)),
                        ("選択範囲", focusedElement?.selectedRange != nil),
                        ("カーソル行番号", focusedElement?.insertionPointLineNumber != nil),
                        ("ラベルテキスト", !(focusedElement?.labelTexts.isEmpty ?? true)),
                        ("Caret Context", hasText(focusedElement?.caretContext)),
                        ("Caret Context Range", focusedElement?.caretContextRange != nil),
                    ])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .innerCardStyle()
            }

            phaseTimingCard(analysis.timings, timeline: analysis.timeline)
        }
        .cardStyle()
    }

    private func artifactsSection(details: DebugCaptureDetails) -> some View {
        let record = details.record
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("補助情報・アーティファクト")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("使用アプリ: \(record.appName ?? "-")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

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
                iconButton(symbol: "photo", helpText: "画像ファイルを表示", disabled: (record.visionImageFilePath == nil)) {
                    viewModel.revealVisionImageFile()
                }
                iconButton(symbol: "text.quote", helpText: "Prompt保存先を開く") {
                    viewModel.openPromptsDirectory()
                }
                iconButton(symbol: "trash", helpText: "削除", role: .destructive) {
                    showingDeleteConfirmation = true
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vision Image")
                        .font(.system(size: 13, weight: .semibold))
                    if let image = visionImage(from: record.visionImageFilePath) {
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

                VStack(alignment: .leading, spacing: 6) {
                    DisclosureGroup("詳細（必要なときだけ表示）") {
                        VStack(alignment: .leading, spacing: 4) {
                            if let context = record.context, !context.isEmpty {
                                Text("context.summary: \(context.visionSummary ?? "-")")
                                Text("context.terms: \(context.visionTerms.joined(separator: ", "))")
                                Text("context.accessibility: \(context.accessibilityText ?? "-")")
                                Text("context.window_text: \(context.windowText ?? "-")")
                            } else {
                                Text("context: なし")
                            }

                            if let accessibility = record.accessibilitySnapshot {
                                Text("bundle: \(accessibility.bundleID ?? "-")")
                                Text("window: \(accessibility.windowTitle ?? "-")")
                                Text("selected: \(accessibility.focusedElement?.selectedText ?? "-")")
                                Text("caret_context: \(accessibility.focusedElement?.caretContext ?? "-")")
                                Text("window_text_chars: \(accessibility.windowTextChars)")
                                if let error = accessibility.error, !error.isEmpty {
                                    Text("accessibility_error: \(error)")
                                        .foregroundStyle(.red)
                                }
                            }

                            Text("sample_rate: \(record.sampleRate)")
                            Text("audio_file: \(record.audioFilePath)")
                            Text("run_dir: \(record.runDirectoryPath)")
                            Text("events: \(record.eventsFilePath)")
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func phaseTimingCard(_ timings: DebugPhaseTimingSummary, timeline: DebugTimelineSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("実行時間 (ms)")
                .font(.system(size: 13, weight: .semibold))

            timelineSection(timeline)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    timingMetricRow("録音", timings.recordingMs)
                    timingMetricRow("STT", timings.sttMs)
                    timingMetricRow("STT finalize", timings.sttFinalizeMs)
                    timingMetricRow("文脈要約 total", timings.visionTotalMs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 5) {
                    timingMetricRow("PostProcess", timings.postProcessMs)
                    timingMetricRow("DirectInput", timings.directInputMs)
                    timingMetricRow("Pipeline(stop後)", timings.pipelineMs)
                    timingMetricRow("End-to-end", timings.endToEndMs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .innerCardStyle()
    }

    private func timelineSection(_ timeline: DebugTimelineSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let bottleneck = timeline.phases.first(where: { $0.id == timeline.bottleneckPhaseID }) {
                    timingBadge(
                        title: "ボトルネック候補",
                        body: "\(bottleneck.title) \(msText(bottleneck.durationMs))ms"
                    )
                }
                if let overlap = timeline.maxOverlap {
                    timingBadge(
                        title: "重なり",
                        body: "\(overlap.leftTitle) × \(overlap.rightTitle) \(msText(overlap.durationMs))ms"
                    )
                }
                Spacer(minLength: 0)
            }

            if timeline.phases.isEmpty || timeline.totalMs <= 0 {
                Text("イベントが不足しているためタイムラインを表示できません。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(timeline.phases) { phase in
                        timelineRow(
                            phase: phase,
                            totalMs: timeline.totalMs,
                            isBottleneck: phase.id == timeline.bottleneckPhaseID
                        )
                    }
                }
            }
        }
    }

    private func timelineRow(phase: DebugTimelinePhase, totalMs: Double, isBottleneck: Bool) -> some View {
        HStack(spacing: 8) {
            Text(phase.title)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 110, alignment: .leading)

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let startRatio = max(0, min(1, phase.startMs / totalMs))
                let durationRatio = max(0.004, min(1, phase.durationMs / totalMs))
                let barOffset = width * startRatio
                let barWidth = max(3, width * durationRatio)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 14)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(timelineColor(for: phase.id))
                        .frame(width: barWidth, height: 14)
                        .offset(x: barOffset)
                        .overlay(alignment: .leading) {
                            if isBottleneck {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.red, lineWidth: 1)
                                    .frame(width: barWidth, height: 14)
                                    .offset(x: barOffset)
                            }
                        }
                }
            }
            .frame(height: 14)

            Text("\(msText(phase.durationMs))ms")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 86, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .help("\(phase.title)\n開始: \(msText(phase.startMs))ms / 終了: \(msText(phase.endMs))ms")
    }

    private func timingBadge(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(body)
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func timelineColor(for phaseID: String) -> Color {
        switch phaseID {
        case "recording":
            return Color.blue.opacity(0.45)
        case "stt":
            return Color.blue
        case "vision":
            return Color.green
        case "context_summary":
            return Color.green
        case "postprocess":
            return Color.orange
        case "direct_input":
            return Color.pink
        case "pipeline":
            return Color.gray
        default:
            return Color.secondary
        }
    }

    private func timingMetricRow(_ name: String, _ value: Double?) -> some View {
        HStack(spacing: 6) {
            Text(name)
            Spacer(minLength: 0)
            Text(msText(value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
        }
        .font(.system(size: 11))
    }

    private func labeledMetric(name: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(name):")
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .help(value)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func availabilityRow(name: String, isAvailable: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(isAvailable ? Color.green : Color.secondary)
            Text(name)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
    }

    private func availabilitySection(title: String, rows: [(String, Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { row in
                availabilityRow(name: row.0, isAvailable: row.1)
            }
        }
    }

    private func hasText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func copyableIDChip(
        label: String,
        value: String,
        copyMessage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text("\(label): \(shortID(value))")
                .font(.system(size: 11, design: .monospaced))
        }
        .buttonStyle(.bordered)
        .help("\(copyMessage)\n\(value)")
    }

    private func shortID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 18 else { return trimmed }
        return "\(trimmed.prefix(8))...\(trimmed.suffix(6))"
    }

    private func msText(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.1f", value)
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

    func innerCardStyle() -> some View {
        self
            .padding(10)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            }
    }
}
