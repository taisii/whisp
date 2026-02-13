import SwiftUI
import WhispCore

struct CandidateFormFields: View {
    @Binding var candidateID: String
    @Binding var model: LLMModel
    @Binding var promptName: String
    @Binding var promptTemplate: String
    @Binding var requireContext: Bool
    @Binding var useCache: Bool

    let variableItems: [PromptVariableItem]
    let editable: Bool
    let onAppendVariable: (String) -> Void

    private let models: [LLMModel] = LLMModelCatalog.selectableModelIDs(for: .benchmarkPromptCandidate)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            groupBox {
                row("candidate_id") {
                    Text(candidateID)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                row("model") {
                    if editable {
                        Picker("model", selection: $model) {
                            ForEach(models, id: \.self) { value in
                                Text(value.rawValue).tag(value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 280)
                    } else {
                        Text(model.rawValue)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                row("tag") {
                    if editable {
                        TextField("例: concise", text: $promptName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    } else {
                        Text(promptName.isEmpty ? "-" : promptName)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            groupBox {
                Text("prompt_template")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                if editable {
                    TextEditor(text: $promptTemplate)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 260)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        }
                } else {
                    ScrollView {
                        Text(promptTemplate.isEmpty ? "-" : promptTemplate)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 200)
                    .background(Color(NSColor.windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    }
                }
            }

            groupBox {
                Text("利用可能な変数")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                ForEach(variableItems) { item in
                    variableRow(item)
                }

                Text("未取得データは空文字で置換されます。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            groupBox {
                if editable {
                    Toggle("require_context", isOn: $requireContext)
                    Toggle("use_cache", isOn: $useCache)
                } else {
                    row("require_context") {
                        Text(requireContext ? "true" : "false")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    row("use_cache") {
                        Text(useCache ? "true" : "false")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func groupBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func variableRow(_ item: PromptVariableItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.token)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text(item.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if editable {
                    Button("挿入") {
                        onAppendVariable(item.token)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Text("例: \(item.sample)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
