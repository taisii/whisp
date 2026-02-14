import AppKit
import SwiftUI
import WhispCore

struct SettingsView: View {
    @State private var config: Config
    @State private var selectedGenerationPrimaryCandidateID: String

    private let onSave: @MainActor (Config) -> Void
    private let onCancel: @MainActor () -> Void
    private let generationCandidates: [BenchmarkCandidate]
    private let preserveGenerationPrimaryOnSave: Bool

    private let recordingModes: [RecordingMode] = [.toggle, .pushToTalk]
    private let sttProviderSpecs: [STTProviderSpec]
    private let visionModes: [VisionContextMode] = VisionContextMode.allCases
    private let llmModels: [LLMModel] = LLMModelCatalog.selectableModelIDs(for: .appSettings)
    private static let noGenerationPrimaryCandidateID = "__none__"
    private static let keepGenerationPrimaryCandidateID = "__keep__"

    init(
        config: Config,
        generationCandidates: [BenchmarkCandidate],
        preserveGenerationPrimaryOnSave: Bool = false,
        onSave: @escaping @MainActor (Config) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        let filteredProviderSpecs = STTProviderCatalog.settingsSpecs()
        _config = State(initialValue: config)
        let candidateIDs = Set(generationCandidates.map(\.id))
        let initialSelection: String
        if let selectedID = config.generationPrimary?.candidateID,
           candidateIDs.contains(selectedID)
        {
            initialSelection = selectedID
        } else if preserveGenerationPrimaryOnSave, config.generationPrimary != nil {
            initialSelection = Self.keepGenerationPrimaryCandidateID
        } else {
            initialSelection = Self.noGenerationPrimaryCandidateID
        }
        _selectedGenerationPrimaryCandidateID = State(initialValue: initialSelection)
        sttProviderSpecs = filteredProviderSpecs
        self.generationCandidates = generationCandidates.sorted { $0.id < $1.id }
        self.preserveGenerationPrimaryOnSave = preserveGenerationPrimaryOnSave
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack {
            Form {
                if preserveGenerationPrimaryOnSave {
                    Section("通知") {
                        Text("Generation候補の読み込みに失敗したため、保存時は既存の Generation 主設定を保持します。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("API Keys") {
                    APIKeyRow(title: "Deepgram API Key", text: binding(\.apiKeys.deepgram))
                    APIKeyRow(title: "Gemini API Key", text: binding(\.apiKeys.gemini))
                    APIKeyRow(title: "OpenAI API Key", text: binding(\.apiKeys.openai))
                    APIKeyRow(title: "Moonshot API Key", text: binding(\.apiKeys.moonshot))
                }

                Section("入力") {
                    TextField("Shortcut (例: Cmd+J)", text: binding(\.shortcut))
                    Picker("録音モード", selection: binding(\.recordingMode)) {
                        ForEach(recordingModes, id: \.self) { mode in
                            Text(recordingModeLabel(mode)).tag(mode)
                        }
                    }
                    Picker("言語", selection: binding(\.inputLanguage)) {
                        Text("自動").tag("auto")
                        Text("日本語").tag("ja")
                        Text("英語").tag("en")
                    }
                }

                Section("モデル") {
                    Picker("STT", selection: binding(\.sttProvider)) {
                        ForEach(sttProviderSpecs, id: \.id) { spec in
                            Text(spec.displayName).tag(spec.id)
                        }
                    }
                    if let sttHint = sttCredentialHint(provider: config.sttProvider) {
                        Text(sttHint)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Picker("LLM", selection: binding(\.llmModel)) {
                        ForEach(llmModels, id: \.self) { model in
                            Text(model.rawValue).tag(model)
                        }
                    }
                }

                Section("Generation主設定") {
                    Picker("Generation candidate", selection: $selectedGenerationPrimaryCandidateID) {
                        if shouldShowKeepExistingGenerationPrimaryOption {
                            Text("既存設定を保持（候補読み込み失敗）")
                                .tag(Self.keepGenerationPrimaryCandidateID)
                        }
                        Text("未設定（従来設定）").tag(Self.noGenerationPrimaryCandidateID)
                        ForEach(generationCandidates, id: \.id) { candidate in
                            Text(generationCandidateLabel(candidate))
                                .tag(candidate.id)
                        }
                    }
                    if shouldShowKeepExistingGenerationPrimaryOption {
                        Text("候補読み込みに失敗したため、保存時は既存の Generation 主設定を保持します。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("コンテキスト") {
                    Toggle("スクリーンショット解析を使う", isOn: binding(\.context.visionEnabled))
                    Picker("スクリーンショット文脈方式", selection: binding(\.context.visionMode)) {
                        ForEach(visionModes, id: \.self) { mode in
                            Text(visionModeLabel(mode)).tag(mode)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("キャンセル") {
                    onCancel()
                }

                Spacer()

                Button("保存") {
                    onSave(configForSave())
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 520, height: 520)
    }

    private func recordingModeLabel(_ mode: RecordingMode) -> String {
        switch mode {
        case .toggle:
            return "トグル"
        case .pushToTalk:
            return "押している間だけ録音"
        }
    }

    private func visionModeLabel(_ mode: VisionContextMode) -> String {
        switch mode {
        case .saveOnly:
            return "保存のみ（解析なし）"
        case .ocr:
            return "OCR抽出"
        }
    }

    private func generationCandidateLabel(_ candidate: BenchmarkCandidate) -> String {
        let name = (candidate.promptName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let promptName = name.isEmpty ? candidate.id : name
        return "\(promptName) (\(candidate.model))"
    }

    private func configForSave() -> Config {
        var updated = config
        if selectedGenerationPrimaryCandidateID == Self.keepGenerationPrimaryCandidateID {
            updated.generationPrimary = config.generationPrimary
            return updated
        }
        if selectedGenerationPrimaryCandidateID == Self.noGenerationPrimaryCandidateID {
            updated.generationPrimary = nil
            return updated
        }
        guard let selected = generationCandidates.first(where: { $0.id == selectedGenerationPrimaryCandidateID }),
              let selection = GenerationPrimarySelectionFactory.makeSelection(candidate: selected)
        else {
            updated.generationPrimary = nil
            return updated
        }
        updated.generationPrimary = selection
        updated.llmModel = selection.snapshot.model
        return updated
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { config[keyPath: keyPath] = $0 }
        )
    }

    private var shouldShowKeepExistingGenerationPrimaryOption: Bool {
        preserveGenerationPrimaryOnSave && config.generationPrimary != nil
    }

    private func sttCredentialHint(provider: STTProvider) -> String? {
        switch provider {
        case .deepgram:
            if config.apiKeys.deepgram.isEmpty {
                return "Deepgram APIキーが未設定です。録音開始前にAPI Keysで設定してください。"
            }
            return nil
        case .whisper:
            if config.apiKeys.openai.isEmpty {
                return "Whisper(OpenAI)用に OpenAI APIキーが必要です。"
            }
            return nil
        case .appleSpeech:
            return "Apple Speech はOS権限のみで利用できます。"
        }
    }
}

private struct APIKeyRow: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            SecureField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            Button("貼り付け") {
                guard let pasted = NSPasteboard.general.string(forType: .string) else {
                    return
                }
                text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .buttonStyle(.bordered)
        }
    }
}
