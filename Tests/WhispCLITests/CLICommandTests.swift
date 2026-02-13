import XCTest
import WhispCore
@testable import whisp

final class CLICommandTests: XCTestCase {
    func testParseSelfCheckCommand() throws {
        let command = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: ["--self-check"]))
        guard case .selfCheck = command else {
            return XCTFail("unexpected command")
        }
    }

    func testParseTopLevelCommandsCoversAllVariants() throws {
        let sttFile = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: ["--stt-file", "/tmp/in.wav"]))
        guard case let .sttFile(path) = sttFile else {
            return XCTFail("unexpected stt-file command")
        }
        XCTAssertEqual(path, "/tmp/in.wav")

        let sttStream = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: [
            "--stt-stream-file", "/tmp/in.wav", "--chunk-ms", "240", "--realtime",
        ]))
        guard case let .sttStream(options) = sttStream else {
            return XCTFail("unexpected stt-stream command")
        }
        XCTAssertEqual(options.path, "/tmp/in.wav")
        XCTAssertEqual(options.chunkMs, 240)
        XCTAssertTrue(options.realtime)

        let pipeline = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: [
            "--pipeline-file", "/tmp/in.wav", "--stt", "rest", "--no-realtime", "--emit", "stdout", "--context-file", "/tmp/context.json",
        ]))
        guard case let .pipeline(options) = pipeline else {
            return XCTFail("unexpected pipeline command")
        }
        XCTAssertEqual(options.path, "/tmp/in.wav")
        XCTAssertEqual(options.sttMode, .rest)
        XCTAssertFalse(options.realtime)
        XCTAssertEqual(options.emitMode, .stdout)
        XCTAssertEqual(options.contextFilePath, "/tmp/context.json")

        let vision = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: [
            "--benchmark-vision-cases", "/tmp/manual.jsonl", "--no-cache",
        ]))
        guard case let .benchmarkVision(options) = vision else {
            return XCTFail("unexpected vision benchmark command")
        }
        XCTAssertEqual(options.jsonlPath, "/tmp/manual.jsonl")
        XCTAssertFalse(options.useCache)

        let stt = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: [
            "--benchmark-stt-cases", "/tmp/manual.jsonl", "--stt", "rest", "--no-realtime",
        ]))
        guard case let .benchmarkSTT(options) = stt else {
            return XCTFail("unexpected stt benchmark command")
        }
        XCTAssertEqual(options.jsonlPath, "/tmp/manual.jsonl")
        XCTAssertEqual(options.sttMode, .rest)
        XCTAssertFalse(options.realtime)

        let generation = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: [
            "--benchmark-generation-cases", "/tmp/manual.jsonl", "--require-context",
        ]))
        guard case let .benchmarkGeneration(options) = generation else {
            return XCTFail("unexpected generation benchmark command")
        }
        XCTAssertEqual(options.jsonlPath, "/tmp/manual.jsonl")
        XCTAssertTrue(options.requireContext)

        let compare = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: [
            "--benchmark-compare",
            "--task", "stt",
            "--cases", "/tmp/manual.jsonl",
            "--candidate-id", "stt-a",
        ]))
        guard case let .benchmarkCompare(compareOptions) = compare else {
            return XCTFail("unexpected benchmark compare command")
        }
        XCTAssertEqual(compareOptions.task, .stt)
        XCTAssertEqual(compareOptions.casesPath, "/tmp/manual.jsonl")
        XCTAssertEqual(compareOptions.candidateIDs, ["stt-a"])

        let listCandidates = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: ["--benchmark-list-candidates"]))
        guard case .benchmarkListCandidates = listCandidates else {
            return XCTFail("unexpected list candidates command")
        }

        let integrity = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: [
            "--benchmark-scan-integrity",
            "--task", "generation",
            "--cases", "/tmp/manual.jsonl",
        ]))
        guard case let .benchmarkScanIntegrity(integrityOptions) = integrity else {
            return XCTFail("unexpected integrity command")
        }
        XCTAssertEqual(integrityOptions.task, .generation)
        XCTAssertEqual(integrityOptions.casesPath, "/tmp/manual.jsonl")
    }

    func testParseUnknownTopLevelCommandReturnsNil() throws {
        let command = try WhispCLI.CLICommand.parse(arguments: ["--unknown"])
        XCTAssertNil(command)
    }

    func testParsePipelineCommandRejectsInvalidSTTMode() {
        XCTAssertThrowsError(try WhispCLI.CLICommand.parse(arguments: [
            "--pipeline-file",
            "/tmp/in.wav",
            "--stt",
            "invalid",
        ]))
    }

    func testParsePipelineCommandRejectsInvalidEmitMode() {
        XCTAssertThrowsError(try WhispCLI.CLICommand.parse(arguments: [
            "--pipeline-file",
            "/tmp/in.wav",
            "--emit",
            "invalid",
        ]))
    }

    func testParsePipelineOptionsAcceptsRealtimeOverrides() throws {
        let options = try WhispCLI.parsePipelineOptions(args: [
            "--pipeline-file",
            "/tmp/in.wav",
            "--no-realtime",
            "--realtime",
            "--chunk-ms",
            "200",
        ])
        XCTAssertTrue(options.realtime)
        XCTAssertEqual(options.chunkMs, 200)
    }

    func testParseVisionBenchmarkOptionsParsesAndRejectsUnknownOption() throws {
        let options = try WhispCLI.parseVisionBenchmarkOptions(args: [
            "--benchmark-vision-cases",
            "/tmp/manual.jsonl",
            "--limit", "8",
            "--no-cache",
        ])
        XCTAssertEqual(options.jsonlPath, "/tmp/manual.jsonl")
        XCTAssertEqual(options.limit, 8)
        XCTAssertFalse(options.useCache)

        XCTAssertThrowsError(try WhispCLI.parseVisionBenchmarkOptions(args: [
            "--benchmark-vision-cases",
            "/tmp/manual.jsonl",
            "--unknown",
        ]))
    }

    func testParseSTTBenchmarkOptionsParsesProviderAndRejectsInvalidValues() throws {
        let options = try WhispCLI.parseSTTBenchmarkOptions(args: [
            "--benchmark-stt-cases",
            "/tmp/manual.jsonl",
            "--stt-provider", "apple_speech",
            "--stt", "rest",
            "--chunk-ms", "200",
            "--no-realtime",
            "--limit", "16",
            "--min-audio-seconds", "2.25",
            "--no-cache",
        ])

        XCTAssertEqual(options.jsonlPath, "/tmp/manual.jsonl")
        XCTAssertEqual(options.sttMode, .rest)
        XCTAssertEqual(options.chunkMs, 200)
        XCTAssertFalse(options.realtime)
        XCTAssertEqual(options.limit, 16)
        XCTAssertEqual(options.minAudioSeconds, 2.25, accuracy: 0.0001)
        XCTAssertFalse(options.useCache)
        XCTAssertEqual(options.sttProvider, .appleSpeech)

        XCTAssertThrowsError(try WhispCLI.parseSTTBenchmarkOptions(args: [
            "--benchmark-stt-cases",
            "/tmp/manual.jsonl",
            "--stt",
            "invalid",
        ]))

        XCTAssertThrowsError(try WhispCLI.parseSTTBenchmarkOptions(args: [
            "--benchmark-stt-cases",
            "/tmp/manual.jsonl",
            "--stt-provider",
            "invalid",
        ]))
    }

    func testParseGenerationBenchmarkOptionsParsesAndRejectsUnknownOption() throws {
        let options = try WhispCLI.parseGenerationBenchmarkOptions(args: [
            "--benchmark-generation-cases",
            "/tmp/manual.jsonl",
            "--limit", "30",
            "--require-context",
            "--llm-eval",
            "--llm-eval-model", "gemini-2.5-flash-lite",
            "--no-cache",
        ])

        XCTAssertEqual(options.jsonlPath, "/tmp/manual.jsonl")
        XCTAssertEqual(options.limit, 30)
        XCTAssertTrue(options.requireContext)
        XCTAssertTrue(options.llmEvalEnabled)
        XCTAssertEqual(options.llmEvalModel, .gemini25FlashLite)
        XCTAssertFalse(options.useCache)

        XCTAssertThrowsError(try WhispCLI.parseGenerationBenchmarkOptions(args: [
            "--benchmark-generation-cases",
            "/tmp/manual.jsonl",
            "--unknown",
        ]))
    }

    func testBenchmarkLogDirOptionIsRejectedInAllBenchmarkParsers() {
        XCTAssertThrowsError(try WhispCLI.parseVisionBenchmarkOptions(args: [
            "--benchmark-vision-cases",
            "/tmp/manual.jsonl",
            "--benchmark-log-dir",
            "/tmp/logs",
        ]))

        XCTAssertThrowsError(try WhispCLI.parseSTTBenchmarkOptions(args: [
            "--benchmark-stt-cases",
            "/tmp/manual.jsonl",
            "--benchmark-log-dir",
            "/tmp/logs",
        ]))

        XCTAssertThrowsError(try WhispCLI.parseGenerationBenchmarkOptions(args: [
            "--benchmark-generation-cases",
            "/tmp/manual.jsonl",
            "--benchmark-log-dir",
            "/tmp/logs",
        ]))
    }

    func testParseBenchmarkCompareOptions() throws {
        let options = try WhispCLI.parseBenchmarkCompareOptions(args: [
            "--benchmark-compare",
            "--task", "generation-battle",
            "--cases", "/tmp/manual.jsonl",
            "--candidate-id", "gen-a",
            "--candidate-id", "gen-b",
            "--judge-model", "gpt-5-nano",
            "--force",
        ])
        XCTAssertEqual(options.task, .generationBattle)
        XCTAssertEqual(options.casesPath, "/tmp/manual.jsonl")
        XCTAssertEqual(options.candidateIDs, ["gen-a", "gen-b"])
        XCTAssertEqual(options.judgeModel, .gpt5Nano)
        XCTAssertTrue(options.force)

        let compareWithoutCases = try WhispCLI.parseBenchmarkCompareOptions(args: [
            "--benchmark-compare",
            "--task", "stt",
            "--candidate-id", "x",
        ])
        XCTAssertEqual(compareWithoutCases.task, .stt)
        XCTAssertEqual(compareWithoutCases.candidateIDs, ["x"])
        XCTAssertEqual(
            URL(fileURLWithPath: compareWithoutCases.casesPath).lastPathComponent,
            "manual_test_cases.jsonl"
        )
    }

    func testParseBenchmarkCompareOptionsRequiresTwoGenerationCandidates() {
        XCTAssertThrowsError(try WhispCLI.parseBenchmarkCompareOptions(args: [
            "--benchmark-compare",
            "--task", "generation-battle",
            "--cases", "/tmp/manual.jsonl",
            "--candidate-id", "gen-a",
        ]))

        XCTAssertThrowsError(try WhispCLI.parseBenchmarkCompareOptions(args: [
            "--benchmark-compare",
            "--task", "generation-battle",
            "--cases", "/tmp/manual.jsonl",
            "--candidate-id", "gen-a",
            "--candidate-id", "gen-b",
            "--candidate-id", "gen-c",
        ]))
    }

    func testParseBenchmarkCompareOptionsRejectsInvalidJudgeModel() {
        XCTAssertThrowsError(try WhispCLI.parseBenchmarkCompareOptions(args: [
            "--benchmark-compare",
            "--task", "generation-battle",
            "--cases", "/tmp/manual.jsonl",
            "--candidate-id", "gen-a",
            "--candidate-id", "gen-b",
            "--judge-model", "invalid-model",
        ]))
    }

    func testParseBenchmarkIntegrityScanOptions() throws {
        let options = try WhispCLI.parseBenchmarkIntegrityScanOptions(args: [
            "--benchmark-scan-integrity",
            "--task", "stt",
            "--cases", "/tmp/manual.jsonl",
        ])
        XCTAssertEqual(options.task, .stt)
        XCTAssertEqual(options.casesPath, "/tmp/manual.jsonl")

        XCTAssertThrowsError(try WhispCLI.parseBenchmarkIntegrityScanOptions(args: [
            "--benchmark-scan-integrity",
            "--task", "vision",
        ]))
    }

    func testResolvedGenerationInputRequiresSttTextOnly() throws {
        let decoder = JSONDecoder()
        let data = Data("""
        {
          "id": "case-a",
          "audio_file": "/tmp/a.wav",
          "labels": { "transcript_gold": "gold text" }
        }
        """.utf8)
        let item = try decoder.decode(ManualBenchmarkCase.self, from: data)
        XCTAssertNil(item.resolvedGenerationInputSTT())
    }

    func testMakePostProcessPromptSupportsContextVariables() {
        var config = Config()
        config.inputLanguage = "ja"
        let context = ContextInfo(
            accessibilityText: "選択中",
            windowText: "議事録本文",
            visionSummary: "会議メモを編集中",
            visionTerms: ["Whisp", "Swift"]
        )
        let prompt = WhispCLI.makePostProcessPrompt(
            config: config,
            sttText: "今日は定例です",
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
        XCTAssertTrue(prompt.contains("選択=選択中"))
        XCTAssertTrue(prompt.contains("画面=議事録本文"))
        XCTAssertTrue(prompt.contains("要約=会議メモを編集中"))
        XCTAssertTrue(prompt.contains("用語=Whisp, Swift"))
    }

    func testParseCandidateBoolOptionRejectsInvalidValue() {
        XCTAssertThrowsError(
            try WhispCLI.parseCandidateBoolOption(
                ["require_context": "invalid-value"],
                key: "require_context",
                defaultValue: false
            )
        )
    }

    func testBuildPairwiseJudgePromptIncludesSTTAndReferencePrinciples() {
        let prompt = WhispCLI.buildPairwiseJudgePrompt(
            referenceText: "期待される文",
            sttInputText: "すってぃー入力",
            candidateAText: "候補A",
            candidateBText: "候補B"
        )

        XCTAssertTrue(prompt.contains("[evaluation_principles]"))
        XCTAssertTrue(prompt.contains("reference_text を主基準"))
        XCTAssertTrue(prompt.contains("STT入力は音声認識結果"))
        XCTAssertTrue(prompt.contains("[stt_input_text]"))
        XCTAssertTrue(prompt.contains("すってぃー入力"))
        XCTAssertFalse(prompt.contains("[cursor_context_text]"))
        XCTAssertFalse(prompt.contains("[screen_context_text]"))
    }

    func testManualBenchmarkCaseDecodesAccessibilityFocusedElement() throws {
        let data = Data("""
        {
          "id": "case-a",
          "audio_file": "/tmp/a.wav",
          "stt_text": "input",
          "accessibility": {
            "focusedElement": {
              "selectedText": "選択中",
              "selectedRange": { "location": 3, "length": 2 },
              "caretContext": "abc|def"
            }
          }
        }
        """.utf8)
        let item = try JSONDecoder().decode(ManualBenchmarkCase.self, from: data)
        XCTAssertEqual(item.accessibility?.focusedElement?.selectedText, "選択中")
        XCTAssertEqual(item.accessibility?.focusedElement?.selectedRange?.location, 3)
        XCTAssertEqual(item.accessibility?.focusedElement?.selectedRange?.length, 2)
        XCTAssertEqual(item.accessibility?.focusedElement?.caretContext, "abc|def")
    }

    func testMultimodalPayloadsEncodeImageParts() throws {
        let openAI = OpenAIChatRequest(
            model: "gpt-4o-mini",
            messages: [
                OpenAIChatMessage(
                    role: "user",
                    content: .parts([
                        .text("prompt"),
                        .imageURL(OpenAIImageURLContent(url: "data:image/png;base64,AAAA")),
                    ])
                ),
            ]
        )
        let openAIJSON = String(data: try JSONEncoder().encode(openAI), encoding: .utf8) ?? ""
        let normalizedOpenAIJSON = openAIJSON.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(normalizedOpenAIJSON.contains("\"image_url\""))
        XCTAssertTrue(normalizedOpenAIJSON.contains("\"data:image/png;base64,AAAA\""))

        let gemini = GeminiMultimodalRequest(contents: [
            GeminiMultimodalContent(role: "user", parts: [
                .text("prompt"),
                .inlineData(GeminiInlineData(mimeType: "image/png", data: "BBBB")),
            ]),
        ])
        let geminiJSON = String(data: try JSONEncoder().encode(gemini), encoding: .utf8) ?? ""
        let normalizedGeminiJSON = geminiJSON.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(normalizedGeminiJSON.contains("\"inlineData\""))
        XCTAssertTrue(normalizedGeminiJSON.contains("\"mimeType\""))
        XCTAssertTrue(normalizedGeminiJSON.contains("\"image/png\""))
        XCTAssertTrue(normalizedGeminiJSON.contains("\"data\":\"BBBB\""))
    }

    func testPairwiseJudgeHasImagePayloadRequiresImageMimePrefix() {
        let bytes = Data([0x00, 0x01, 0x02])
        XCTAssertTrue(WhispCLI.pairwiseJudgeHasImagePayload(
            visionImageData: bytes,
            visionImageMimeType: "image/png"
        ))
        XCTAssertFalse(WhispCLI.pairwiseJudgeHasImagePayload(
            visionImageData: bytes,
            visionImageMimeType: "png"
        ))
        XCTAssertFalse(WhispCLI.pairwiseJudgeHasImagePayload(
            visionImageData: bytes,
            visionImageMimeType: nil
        ))
        XCTAssertFalse(WhispCLI.pairwiseJudgeHasImagePayload(
            visionImageData: nil,
            visionImageMimeType: "image/png"
        ))
    }

    func testMakeGenerationPairwiseBenchmarkKeyDoesNotRequireJudgeAPIKey() throws {
        let now = WhispTime.isoNow()
        let candidateA = BenchmarkCandidate(
            id: "gen-a",
            task: .generation,
            model: "gpt-4o-mini",
            generationPromptTemplate: "A",
            options: [:],
            createdAt: now,
            updatedAt: now
        )
        let candidateB = BenchmarkCandidate(
            id: "gen-b",
            task: .generation,
            model: "gemini-2.5-flash-lite",
            generationPromptTemplate: "B",
            options: [:],
            createdAt: now,
            updatedAt: now
        )

        let key = try WhispCLI.makeGenerationPairwiseBenchmarkKey(
            candidateA: candidateA,
            candidateB: candidateB,
            datasetPath: "/tmp/manual.jsonl",
            datasetHash: "dataset-hash",
            judgeModel: .gpt5Nano
        )
        XCTAssertEqual(key.task, .generation)
        XCTAssertEqual(key.datasetPath, "/tmp/manual.jsonl")
        XCTAssertEqual(key.datasetHash, "dataset-hash")
        XCTAssertEqual(key.candidateID, "pair:gen-a__vs__gen-b")
        XCTAssertFalse(key.runtimeOptionsHash.isEmpty)
    }
}
