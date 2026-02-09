import Foundation

public let deepgramNovaPerMinute = 0.0077
public let geminiFlashLiteInputPerMillion = 0.10
public let geminiFlashLiteOutputPerMillion = 0.40
public let gpt4oMiniInputPerMillion = 0.15
public let gpt4oMiniOutputPerMillion = 0.60

public struct DailyCostBreakdown: Equatable, Sendable {
    public let deepgramCostUSD: Double
    public let geminiCostUSD: Double
    public let openaiCostUSD: Double
    public let totalCostUSD: Double

    public init(deepgramCostUSD: Double, geminiCostUSD: Double, openaiCostUSD: Double, totalCostUSD: Double) {
        self.deepgramCostUSD = deepgramCostUSD
        self.geminiCostUSD = geminiCostUSD
        self.openaiCostUSD = openaiCostUSD
        self.totalCostUSD = totalCostUSD
    }
}

public func calculateDeepgramCost(durationSeconds: Double) -> Double {
    (durationSeconds / 60.0) * deepgramNovaPerMinute
}

public func calculateGeminiCost(promptTokens: Int, completionTokens: Int) -> Double {
    let inputCost = (Double(promptTokens) / 1_000_000.0) * geminiFlashLiteInputPerMillion
    let outputCost = (Double(completionTokens) / 1_000_000.0) * geminiFlashLiteOutputPerMillion
    return inputCost + outputCost
}

public func calculateOpenAICost(promptTokens: Int, completionTokens: Int) -> Double {
    let inputCost = (Double(promptTokens) / 1_000_000.0) * gpt4oMiniInputPerMillion
    let outputCost = (Double(completionTokens) / 1_000_000.0) * gpt4oMiniOutputPerMillion
    return inputCost + outputCost
}

public func calculateLLMCost(model: String, promptTokens: Int, completionTokens: Int) -> Double {
    if model.contains("gemini") {
        return calculateGeminiCost(promptTokens: promptTokens, completionTokens: completionTokens)
    }
    return calculateOpenAICost(promptTokens: promptTokens, completionTokens: completionTokens)
}

public func calculateSTTCost(_ usage: STTUsage) -> Double {
    calculateDeepgramCost(durationSeconds: usage.durationSeconds)
}

public func calculateTotalCost(stt: STTUsage?, llm: LLMUsage?) -> Double {
    let sttCost = stt.map(calculateSTTCost) ?? 0
    let llmCost = llm.map { calculateLLMCost(model: $0.model, promptTokens: $0.promptTokens, completionTokens: $0.completionTokens) } ?? 0
    return sttCost + llmCost
}

public func calculateDailyCost(_ daily: DailyUsage) -> DailyCostBreakdown {
    let deepgram = calculateDeepgramCost(durationSeconds: daily.deepgramSeconds)
    let gemini = calculateGeminiCost(promptTokens: daily.geminiPromptTokens, completionTokens: daily.geminiCompletionTokens)
    let openai = calculateOpenAICost(promptTokens: daily.openaiPromptTokens, completionTokens: daily.openaiCompletionTokens)
    return DailyCostBreakdown(
        deepgramCostUSD: deepgram,
        geminiCostUSD: gemini,
        openaiCostUSD: openai,
        totalCostUSD: deepgram + gemini + openai
    )
}
