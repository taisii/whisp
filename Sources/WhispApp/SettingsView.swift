import AppKit
import SwiftUI
import WhispCore

struct SettingsView: View {
    @State private var config: Config

    private let onSave: @MainActor (Config) -> Void
    private let onCancel: @MainActor () -> Void

    private let recordingModes: [RecordingMode] = [.toggle, .pushToTalk]
    private let sttProviders: [STTProvider] = [.deepgram, .whisper, .appleSpeech]
    private let visionModes: [VisionContextMode] = VisionContextMode.allCases
    private let llmModels: [LLMModel] = LLMModelCatalog.selectableModelIDs(for: .appSettings)

    init(config: Config, onSave: @escaping @MainActor (Config) -> Void, onCancel: @escaping @MainActor () -> Void) {
        _config = State(initialValue: config)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack {
            Form {
                Section("API Keys") {
                    APIKeyRow(title: "Deepgram API Key", text: binding(\.apiKeys.deepgram))
                    APIKeyRow(title: "Gemini API Key", text: binding(\.apiKeys.gemini))
                    APIKeyRow(title: "OpenAI API Key", text: binding(\.apiKeys.openai))
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
                        ForEach(sttProviders, id: \.self) { provider in
                            Text(sttProviderLabel(provider)).tag(provider)
                        }
                    }
                    Picker("LLM", selection: binding(\.llmModel)) {
                        ForEach(llmModels, id: \.self) { model in
                            Text(model.rawValue).tag(model)
                        }
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
                    onSave(config)
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

    private func sttProviderLabel(_ provider: STTProvider) -> String {
        switch provider {
        case .deepgram:
            return "Deepgram (Streaming)"
        case .whisper:
            return "Whisper (OpenAI)"
        case .appleSpeech:
            return "Apple Speech (OS内蔵)"
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

    private func binding<T>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { config[keyPath: keyPath] = $0 }
        )
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
