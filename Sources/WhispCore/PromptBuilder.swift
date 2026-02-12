import CryptoKit
import Foundation

public let defaultPostProcessPromptTemplate = """
以下の音声認識結果を、意味を保って自然な文に整形してください。
出力は整形後テキストのみ。

ルール:
- フィラー（えーと、あのー等）を除去
- 誤認識された技術用語を文脈で修正

入力: {STT結果}
"""

public func canonicalPromptTemplate(_ template: String) -> String {
    template
        .replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

public func promptTemplateHash(_ template: String) -> String {
    let canonical = canonicalPromptTemplate(template)
    let material = "prompt-v1|\(canonical)"
    let digest = SHA256.hash(data: Data(material.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

public struct PromptVariableDescriptor: Equatable, Sendable {
    public let token: String
    public let description: String
    public let sample: String

    public init(token: String, description: String, sample: String) {
        self.token = token
        self.description = description
        self.sample = sample
    }
}

public let sttResultPromptVariableToken = "{STT結果}"

public let generationPromptVariableDescriptors: [PromptVariableDescriptor] = [
    PromptVariableDescriptor(
        token: sttResultPromptVariableToken,
        description: "ケースの stt_text を挿入",
        sample: "今日は13時から定例です"
    ),
    PromptVariableDescriptor(
        token: "{選択テキスト}",
        description: "context.accessibilityText を挿入",
        sample: "選択中の文章"
    ),
    PromptVariableDescriptor(
        token: "{画面テキスト}",
        description: "context.windowText を挿入",
        sample: "ウィンドウ内の可視テキスト"
    ),
    PromptVariableDescriptor(
        token: "{画面要約}",
        description: "context.visionSummary を挿入",
        sample: "エディタでSwiftコードを編集中"
    ),
    PromptVariableDescriptor(
        token: "{専門用語候補}",
        description: "context.visionTerms をカンマ区切りで挿入",
        sample: "BenchmarkRunRecord, PromptBuilder"
    ),
]

public struct ContextInfo: Codable, Equatable, Sendable {
    public var accessibilityText: String?
    public var windowText: String?
    public var visionSummary: String?
    public var visionTerms: [String]

    public init(
        accessibilityText: String? = nil,
        windowText: String? = nil,
        visionSummary: String? = nil,
        visionTerms: [String] = []
    ) {
        self.accessibilityText = accessibilityText
        self.windowText = windowText
        self.visionSummary = visionSummary
        self.visionTerms = visionTerms
    }

    public var isEmpty: Bool {
        let accessibilityEmpty = accessibilityText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let windowTextEmpty = windowText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let summaryEmpty = visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        return accessibilityEmpty && windowTextEmpty && summaryEmpty && visionTerms.isEmpty
    }
}

public struct VisionContext: Equatable, Sendable {
    public var summary: String
    public var terms: [String]

    public init(summary: String, terms: [String]) {
        self.summary = summary
        self.terms = terms
    }
}

public struct PostProcessResult: Equatable, Sendable {
    public let text: String
    public let usage: LLMUsage?

    public init(text: String, usage: LLMUsage?) {
        self.text = text
        self.usage = usage
    }
}

public func languageLabel(_ languageHint: String) -> String {
    switch languageHint {
    case "ja":
        return "日本語"
    case "en":
        return "英語"
    default:
        return "自動判定（日本語/英語）"
    }
}

private let sttResultToken = sttResultPromptVariableToken
private let contextPromptVariableTokens: [String] = generationPromptVariableDescriptors
    .map(\.token)
    .filter { $0 != sttResultToken }

private func contextVariableValue(forToken token: String, context: ContextInfo?) -> String {
    guard let context else {
        return ""
    }
    switch token {
    case "{選択テキスト}":
        return context.accessibilityText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    case "{画面テキスト}":
        return context.windowText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    case "{画面要約}":
        return context.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    case "{専門用語候補}":
        return context.visionTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    default:
        return ""
    }
}

private func hasContextPromptVariable(in template: String) -> Bool {
    contextPromptVariableTokens.contains { template.contains($0) }
}

private func applyTemplate(
    _ template: String,
    sttResult: String,
    languageHint: String,
    context: ContextInfo?
) -> String {
    let label = languageLabel(languageHint)
    var prompt = template
        .replacingOccurrences(of: "{言語}", with: label)
        .replacingOccurrences(of: sttResultToken, with: sttResult)

    for token in contextPromptVariableTokens {
        prompt = prompt.replacingOccurrences(
            of: token,
            with: contextVariableValue(forToken: token, context: context)
        )
    }

    if !template.contains(sttResultToken) {
        prompt += "\n\n入力: \(sttResult)"
    }
    return prompt
}

private func resolveAppTemplate(appName: String?, rules: [AppPromptRule]) -> String? {
    guard let appName else { return nil }
    let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    for rule in rules where rule.appName.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
        let template = rule.template.trimmingCharacters(in: .whitespacesAndNewlines)
        if !template.isEmpty {
            return template
        }
    }
    return nil
}

private func appendContext(to prompt: inout String, context: ContextInfo) {
    guard !context.isEmpty else { return }

    var lines: [String] = []
    if let text = context.accessibilityText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
        lines.append("選択テキスト: \(text)")
    }
    if let summary = context.visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
        lines.append("画面の要約: \(summary)")
    }
    if !context.visionTerms.isEmpty {
        lines.append("専門用語候補: \(context.visionTerms.joined(separator: ", "))")
    }
    guard !lines.isEmpty else { return }

    prompt += "\n\n画面コンテキスト:\n"
    for line in lines {
        prompt += "- \(line)\n"
    }
}

public func buildPrompt(
    sttResult: String,
    languageHint: String,
    appName: String?,
    appPromptRules: [AppPromptRule],
    context: ContextInfo?,
    templateOverride: String? = nil
) -> String {
    let override = (templateOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let template = !override.isEmpty
        ? override
        : (resolveAppTemplate(appName: appName, rules: appPromptRules) ?? defaultPostProcessPromptTemplate)
    let containsContextVariable = hasContextPromptVariable(in: template)
    var prompt = applyTemplate(
        template,
        sttResult: sttResult,
        languageHint: languageHint,
        context: context
    )
    if let context, !containsContextVariable {
        appendContext(to: &prompt, context: context)
    }
    return prompt
}

public struct GeminiUsageMetadata: Decodable, Equatable, Sendable {
    public let promptTokenCount: Int
    public let candidatesTokenCount: Int

    enum CodingKeys: String, CodingKey {
        case promptTokenCount
        case candidatesTokenCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptTokenCount = try c.decodeIfPresent(Int.self, forKey: .promptTokenCount) ?? 0
        candidatesTokenCount = try c.decodeIfPresent(Int.self, forKey: .candidatesTokenCount) ?? 0
    }
}

public struct GeminiPartResponse: Decodable, Equatable, Sendable {
    public let text: String?
}

public struct GeminiContentResponse: Decodable, Equatable, Sendable {
    public let parts: [GeminiPartResponse]

    public var joinedText: String {
        parts.compactMap { $0.text }.joined()
    }
}

public struct GeminiCandidate: Decodable, Equatable, Sendable {
    public let content: GeminiContentResponse
}

public struct GeminiResponse: Decodable, Equatable, Sendable {
    public let candidates: [GeminiCandidate]
    public let usageMetadata: GeminiUsageMetadata?
}

public struct OpenAIMessageResponse: Decodable, Equatable, Sendable {
    public let content: String
}

public struct OpenAIChoice: Decodable, Equatable, Sendable {
    public let message: OpenAIMessageResponse
}

public struct OpenAIUsage: Decodable, Equatable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

public struct OpenAIResponse: Decodable, Equatable, Sendable {
    public let choices: [OpenAIChoice]
    public let usage: OpenAIUsage?
}

private struct VisionContextJSON: Decodable {
    let summary: String?
    let terms: [String]?
}

public func parseVisionContext(_ text: String) -> VisionContext? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate: String

    if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
        candidate = trimmed
    } else {
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end
        else {
            return nil
        }
        candidate = String(trimmed[start...end])
    }

    guard let parsed = try? JSONDecoder().decode(VisionContextJSON.self, from: Data(candidate.utf8)) else {
        return nil
    }

    let summary = parsed.summary ?? ""
    let terms = parsed.terms ?? []
    if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && terms.isEmpty {
        return nil
    }
    return VisionContext(summary: summary, terms: terms)
}
