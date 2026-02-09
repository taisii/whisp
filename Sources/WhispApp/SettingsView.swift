import AppKit
import SwiftUI
import WhispCore

struct SettingsView: View {
    private enum ActiveAlert: Int, Identifiable {
        case confirmEnableAccessibility
        case accessibilityNotGranted

        var id: Int { rawValue }
    }

    @State private var config: Config
    @State private var activeAlert: ActiveAlert?

    private let onSave: @MainActor (Config) -> Void
    private let onCancel: @MainActor () -> Void

    private let recordingModes: [RecordingMode] = [.toggle, .pushToTalk]
    private let llmModels: [LLMModel] = [.gemini25FlashLite, .gemini25FlashLiteAudio, .gpt4oMini, .gpt5Nano]

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
                    Picker("LLM", selection: binding(\.llmModel)) {
                        ForEach(llmModels, id: \.self) { model in
                            Text(model.rawValue).tag(model)
                        }
                    }
                }

                Section("コンテキスト") {
                    Toggle("アクセシビリティ情報を使う", isOn: accessibilityToggleBinding)
                    Toggle("スクリーンショット解析を使う", isOn: binding(\.context.visionEnabled))
                    Button("アクセシビリティ権限を再確認") {
                        refreshAccessibilitySettingFromSystem()
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
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .confirmEnableAccessibility:
                return Alert(
                    title: Text("アクセシビリティ権限を要求しますか？"),
                    message: Text("有効化すると、Whisp が他アプリへテキストを直接入力できるようになります。"),
                    primaryButton: .default(Text("要求する")) {
                        requestAccessibilityAndEnable()
                    },
                    secondaryButton: .cancel(Text("キャンセル"))
                )
            case .accessibilityNotGranted:
                return Alert(
                    title: Text("アクセシビリティ権限が未許可です"),
                    message: Text("システム設定で Whisp を許可した後に、再度オンにしてください。"),
                    primaryButton: .default(Text("設定を開く")) {
                        DirectInput.openAccessibilitySettings()
                    },
                    secondaryButton: .cancel(Text("閉じる"))
                )
            }
        }
    }

    private func recordingModeLabel(_ mode: RecordingMode) -> String {
        switch mode {
        case .toggle:
            return "トグル"
        case .pushToTalk:
            return "押している間だけ録音"
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { config[keyPath: keyPath] = $0 }
        )
    }

    private var accessibilityToggleBinding: Binding<Bool> {
        Binding(
            get: { config.context.accessibilityEnabled },
            set: { newValue in
                if !newValue {
                    config.context.accessibilityEnabled = false
                    return
                }

                if DirectInput.isAccessibilityTrusted() {
                    config.context.accessibilityEnabled = true
                } else {
                    config.context.accessibilityEnabled = false
                    activeAlert = .confirmEnableAccessibility
                }
            }
        )
    }

    private func requestAccessibilityAndEnable() {
        let trusted = DirectInput.requestAccessibilityPermission(prompt: true)
        if trusted || DirectInput.isAccessibilityTrusted() {
            config.context.accessibilityEnabled = true
            return
        }

        config.context.accessibilityEnabled = false
        activeAlert = .accessibilityNotGranted
    }

    private func refreshAccessibilitySettingFromSystem() {
        if DirectInput.isAccessibilityTrusted() {
            config.context.accessibilityEnabled = true
        } else {
            config.context.accessibilityEnabled = false
            activeAlert = .accessibilityNotGranted
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
