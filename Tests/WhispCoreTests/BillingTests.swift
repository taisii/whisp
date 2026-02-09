import XCTest
@testable import WhispCore

final class BillingTests: XCTestCase {
    func testDeepgramCostOneMinute() {
        let cost = calculateDeepgramCost(durationSeconds: 60.0)
        XCTAssertEqual(cost, 0.0077, accuracy: 0.0001)
    }

    func testDeepgramCostHalfMinute() {
        let cost = calculateDeepgramCost(durationSeconds: 30.0)
        XCTAssertEqual(cost, 0.00385, accuracy: 0.0001)
    }

    func testGeminiCostCalculation() {
        let cost = calculateGeminiCost(promptTokens: 1_000_000, completionTokens: 1_000_000)
        XCTAssertEqual(cost, 0.50, accuracy: 0.0001)
    }

    func testGeminiCostSmallTokens() {
        let cost = calculateGeminiCost(promptTokens: 1000, completionTokens: 500)
        XCTAssertEqual(cost, 0.0003, accuracy: 0.00001)
    }

    func testOpenAICostCalculation() {
        let cost = calculateOpenAICost(promptTokens: 1_000_000, completionTokens: 1_000_000)
        XCTAssertEqual(cost, 0.75, accuracy: 0.0001)
    }

    func testLLMCostRoutesCorrectly() {
        let geminiCost = calculateLLMCost(model: "gemini-2.5-flash-lite", promptTokens: 1000, completionTokens: 500)
        let openAICost = calculateLLMCost(model: "gpt-4o-mini", promptTokens: 1000, completionTokens: 500)
        XCTAssertLessThan(geminiCost, openAICost)
    }

    func testTotalCostCombinesSTTAndLLM() {
        let stt = STTUsage(durationSeconds: 60.0, requestID: nil)
        let llm = LLMUsage(model: "gemini-2.5-flash-lite", promptTokens: 1000, completionTokens: 500)

        let total = calculateTotalCost(stt: stt, llm: llm)
        let expected = calculateDeepgramCost(durationSeconds: 60.0) + calculateGeminiCost(promptTokens: 1000, completionTokens: 500)

        XCTAssertEqual(total, expected, accuracy: 0.00001)
    }

    func testDailyCostBreakdown() {
        let daily = DailyUsage(
            date: "2025-01-18",
            deepgramSeconds: 120.0,
            deepgramRequests: 5,
            geminiPromptTokens: 5000,
            geminiCompletionTokens: 2000,
            geminiRequests: 5,
            openaiPromptTokens: 1000,
            openaiCompletionTokens: 500,
            openaiRequests: 2
        )

        let breakdown = calculateDailyCost(daily)
        XCTAssertEqual(breakdown.deepgramCostUSD, calculateDeepgramCost(durationSeconds: 120.0), accuracy: 0.00001)
        XCTAssertEqual(breakdown.geminiCostUSD, calculateGeminiCost(promptTokens: 5000, completionTokens: 2000), accuracy: 0.00001)
        XCTAssertEqual(breakdown.openaiCostUSD, calculateOpenAICost(promptTokens: 1000, completionTokens: 500), accuracy: 0.00001)
        XCTAssertEqual(
            breakdown.totalCostUSD,
            breakdown.deepgramCostUSD + breakdown.geminiCostUSD + breakdown.openaiCostUSD,
            accuracy: 0.00001
        )
    }
}
