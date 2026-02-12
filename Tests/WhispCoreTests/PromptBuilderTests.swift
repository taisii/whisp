import Foundation
import XCTest
@testable import WhispCore

final class PromptBuilderTests: XCTestCase {
    func testPromptIncludesInput() {
        let prompt = buildPrompt(sttResult: "テストです", languageHint: "ja", appName: nil, appPromptRules: [], context: nil)
        XCTAssertTrue(prompt.contains("入力: テストです"))
    }

    func testAppPromptReplacesPlaceholders() {
        let prompt = buildPrompt(
            sttResult: "こんにちは",
            languageHint: "en",
            appName: "Slack",
            appPromptRules: [AppPromptRule(appName: "Slack", template: "出力は{言語}。入力={STT結果}")],
            context: nil
        )
        XCTAssertTrue(prompt.contains("出力は英語。入力=こんにちは"))
    }

    func testAppPromptAppendsInputWhenMissing() {
        let prompt = buildPrompt(
            sttResult: "テスト",
            languageHint: "ja",
            appName: "Slack",
            appPromptRules: [AppPromptRule(appName: "Slack", template: "指示だけ")],
            context: nil
        )
        XCTAssertTrue(prompt.contains("指示だけ"))
        XCTAssertTrue(prompt.contains("入力: テスト"))
    }

    func testPromptAppendsContextBlock() {
        let context = ContextInfo(
            accessibilityText: "選択された単語",
            windowText: "直前の会話ログ",
            visionSummary: "エディタでGoファイル編集中",
            visionTerms: ["func main", "http.Server"]
        )
        let prompt = buildPrompt(sttResult: "テスト", languageHint: "ja", appName: nil, appPromptRules: [], context: context)

        XCTAssertTrue(prompt.contains("画面コンテキスト"))
        XCTAssertTrue(prompt.contains("選択テキスト: 選択された単語"))
        XCTAssertFalse(prompt.contains("同一ウィンドウ本文: 直前の会話ログ"))
        XCTAssertTrue(prompt.contains("画面の要約: エディタでGoファイル編集中"))
        XCTAssertTrue(prompt.contains("専門用語候補: func main, http.Server"))
    }

    func testPromptReplacesContextVariables() {
        let context = ContextInfo(
            accessibilityText: "選択中の文",
            windowText: "会議メモの本文",
            visionSummary: "Slackで議事録を編集",
            visionTerms: ["Whisp", "Benchmark"]
        )
        let prompt = buildPrompt(
            sttResult: "今日は定例です",
            languageHint: "ja",
            appName: nil,
            appPromptRules: [],
            context: context,
            templateOverride: """
            入力={STT結果}
            選択={選択テキスト}
            画面={画面テキスト}
            要約={画面要約}
            用語={専門用語候補}
            """
        )

        XCTAssertTrue(prompt.contains("入力=今日は定例です"))
        XCTAssertTrue(prompt.contains("選択=選択中の文"))
        XCTAssertTrue(prompt.contains("画面=会議メモの本文"))
        XCTAssertTrue(prompt.contains("要約=Slackで議事録を編集"))
        XCTAssertTrue(prompt.contains("用語=Whisp, Benchmark"))
    }

    func testPromptReplacesMissingContextVariablesWithEmptyString() {
        let prompt = buildPrompt(
            sttResult: "テスト",
            languageHint: "ja",
            appName: nil,
            appPromptRules: [],
            context: nil,
            templateOverride: "選択={選択テキスト}|画面={画面テキスト}|要約={画面要約}|用語={専門用語候補}"
        )

        XCTAssertEqual(prompt, "選択=|画面=|要約=|用語=\n\n入力: テスト")
    }

    func testPromptSkipsContextBlockWhenTemplateContainsContextVariable() {
        let context = ContextInfo(
            accessibilityText: "選択された単語",
            visionSummary: "IDEで編集中",
            visionTerms: ["Swift"]
        )
        let prompt = buildPrompt(
            sttResult: "テスト",
            languageHint: "ja",
            appName: nil,
            appPromptRules: [],
            context: context,
            templateOverride: "入力={STT結果}\n要約={画面要約}"
        )

        XCTAssertTrue(prompt.contains("要約=IDEで編集中"))
        XCTAssertFalse(prompt.contains("画面コンテキスト:"))
    }

    func testParseGeminiResponseWithUsage() throws {
        let json = """
        {
          "candidates": [
            { "content": { "parts": [ { "text": "整形済み" } ] } }
          ],
          "usageMetadata": {
            "promptTokenCount": 100,
            "candidatesTokenCount": 50
          }
        }
        """
        let parsed = try JSONDecoder().decode(GeminiResponse.self, from: Data(json.utf8))
        XCTAssertEqual(parsed.candidates.first?.content.joinedText, "整形済み")
        XCTAssertEqual(parsed.usageMetadata?.promptTokenCount, 100)
        XCTAssertEqual(parsed.usageMetadata?.candidatesTokenCount, 50)
    }

    func testParseGeminiResponseJoinsMultipartText() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "前半です。" },
                  { "inlineData": { "mimeType": "text/plain", "data": "ZHVtbXk=" } },
                  { "text": "後半です。" }
                ]
              }
            }
          ]
        }
        """
        let parsed = try JSONDecoder().decode(GeminiResponse.self, from: Data(json.utf8))
        XCTAssertEqual(parsed.candidates.first?.content.joinedText, "前半です。後半です。")
    }

    func testParseOpenAIResponseWithUsage() throws {
        let json = """
        {
          "choices": [
            { "message": { "content": "整形済み" } }
          ],
          "usage": {
            "prompt_tokens": 200,
            "completion_tokens": 100
          }
        }
        """
        let parsed = try JSONDecoder().decode(OpenAIResponse.self, from: Data(json.utf8))
        XCTAssertEqual(parsed.choices.first?.message.content, "整形済み")
        XCTAssertEqual(parsed.usage?.promptTokens, 200)
        XCTAssertEqual(parsed.usage?.completionTokens, 100)
    }

    func testParseVisionContext() {
        let json = "{\"summary\":\"IDE\",\"terms\":[\"Swift\",\"AppKit\"]}"
        let parsed = parseVisionContext(json)
        XCTAssertEqual(parsed, VisionContext(summary: "IDE", terms: ["Swift", "AppKit"]))
    }

    func testParseVisionContextFromWrappedText() {
        let text = "result: {\"summary\":\"編集\",\"terms\":[\"Xcode\"]} done"
        let parsed = parseVisionContext(text)
        XCTAssertEqual(parsed, VisionContext(summary: "編集", terms: ["Xcode"]))
    }
}
