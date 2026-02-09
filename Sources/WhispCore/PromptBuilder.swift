import Foundation

private let defaultPromptTemplate = """
以下の音声認識結果を、意味を保って自然な文に整形してください。
出力は整形後テキストのみ。

ルール:
- フィラー（えーと、あのー等）を除去
- 誤認識された技術用語を文脈で修正

入力: {STT結果}
"""

public struct ContextInfo: Codable, Equatable, Sendable {
    public var accessibilityText: String?
    public var visionSummary: String?
    public var visionTerms: [String]

    public init(accessibilityText: String? = nil, visionSummary: String? = nil, visionTerms: [String] = []) {
        self.accessibilityText = accessibilityText
        self.visionSummary = visionSummary
        self.visionTerms = visionTerms
    }

    public var isEmpty: Bool {
        let accessibilityEmpty = accessibilityText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let summaryEmpty = visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        return accessibilityEmpty && summaryEmpty && visionTerms.isEmpty
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

private func applyTemplate(_ template: String, sttResult: String, languageHint: String) -> String {
    let label = languageLabel(languageHint)
    var prompt = template
        .replacingOccurrences(of: "{言語}", with: label)
        .replacingOccurrences(of: "{STT結果}", with: sttResult)

    if !template.contains("{STT結果}") {
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
    context: ContextInfo?
) -> String {
    let template = resolveAppTemplate(appName: appName, rules: appPromptRules) ?? defaultPromptTemplate
    var prompt = applyTemplate(template, sttResult: sttResult, languageHint: languageHint)
    if let context {
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
