import XCTest
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

        let manual = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: [
            "--benchmark-manual-cases", "/tmp/manual.jsonl", "--limit", "10",
        ]))
        guard case let .benchmarkManual(options) = manual else {
            return XCTFail("unexpected manual benchmark command")
        }
        XCTAssertEqual(options.jsonlPath, "/tmp/manual.jsonl")
        XCTAssertEqual(options.limit, 10)

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
    }

    func testParseBenchmarkE2EDelegatesToManualOptions() throws {
        let command = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: [
            "--benchmark-e2e-cases",
            "/tmp/manual.jsonl",
            "--stt", "rest",
            "--chunk-ms", "300",
            "--no-realtime",
            "--limit", "20",
            "--require-context",
            "--min-audio-seconds", "1.25",
            "--benchmark-log-dir", "/tmp/bench",
            "--intent-source", "silver",
            "--no-intent-judge",
            "--judge-model", "gpt-5-nano",
            "--min-label-confidence", "0.7",
        ]))

        guard case let .benchmarkE2E(options) = command else {
            return XCTFail("unexpected command")
        }

        XCTAssertEqual(options.jsonlPath, "/tmp/manual.jsonl")
        XCTAssertEqual(options.sttMode, .rest)
        XCTAssertEqual(options.chunkMs, 300)
        XCTAssertFalse(options.realtime)
        XCTAssertEqual(options.limit, 20)
        XCTAssertTrue(options.requireContext)
        XCTAssertEqual(options.minAudioSeconds, 1.25, accuracy: 0.0001)
        XCTAssertEqual(options.benchmarkLogDir, "/tmp/bench")
        XCTAssertEqual(options.intentSource, .silver)
        XCTAssertFalse(options.intentJudgeEnabled)
        XCTAssertEqual(options.intentJudgeModel, .gpt5Nano)
        XCTAssertEqual(options.minLabelConfidence, 0.7)
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

    func testParseManualBenchmarkOptionsParsesCombinations() throws {
        let options = try WhispCLI.parseManualBenchmarkOptions(args: [
            "--benchmark-manual-cases",
            "/tmp/manual.jsonl",
            "--stt", "rest",
            "--chunk-ms", "260",
            "--no-realtime",
            "--limit", "12",
            "--require-context",
            "--min-audio-seconds", "1.5",
            "--benchmark-log-dir", "/tmp/logs",
            "--intent-source", "gold",
            "--intent-judge",
            "--judge-model", "gemini-2.5-flash-lite",
            "--min-label-confidence", "0.5",
        ])

        XCTAssertEqual(options.jsonlPath, "/tmp/manual.jsonl")
        XCTAssertEqual(options.sttMode, .rest)
        XCTAssertEqual(options.chunkMs, 260)
        XCTAssertFalse(options.realtime)
        XCTAssertEqual(options.limit, 12)
        XCTAssertTrue(options.requireContext)
        XCTAssertEqual(options.minAudioSeconds, 1.5, accuracy: 0.0001)
        XCTAssertEqual(options.benchmarkLogDir, "/tmp/logs")
        XCTAssertEqual(options.intentSource, .gold)
        XCTAssertTrue(options.intentJudgeEnabled)
        XCTAssertEqual(options.intentJudgeModel, .gemini25FlashLite)
        XCTAssertEqual(options.minLabelConfidence, 0.5)
    }

    func testParseManualBenchmarkOptionsRejectsInvalidConfidenceRange() {
        XCTAssertThrowsError(try WhispCLI.parseManualBenchmarkOptions(args: [
            "--benchmark-manual-cases",
            "/tmp/manual.jsonl",
            "--min-label-confidence",
            "1.1",
        ]))
    }

    func testParseManualBenchmarkOptionsRejectsInvalidIntentSource() {
        XCTAssertThrowsError(try WhispCLI.parseManualBenchmarkOptions(args: [
            "--benchmark-manual-cases",
            "/tmp/manual.jsonl",
            "--intent-source",
            "invalid",
        ]))
    }

    func testParseManualBenchmarkOptionsRejectsUnknownOption() {
        XCTAssertThrowsError(try WhispCLI.parseManualBenchmarkOptions(args: [
            "--benchmark-manual-cases",
            "/tmp/manual.jsonl",
            "--unknown",
        ]))
    }

    func testParseVisionBenchmarkOptionsParsesAndRejectsUnknownOption() throws {
        let options = try WhispCLI.parseVisionBenchmarkOptions(args: [
            "--benchmark-vision-cases",
            "/tmp/manual.jsonl",
            "--limit", "8",
            "--benchmark-log-dir", "/tmp/logs",
            "--no-cache",
        ])
        XCTAssertEqual(options.jsonlPath, "/tmp/manual.jsonl")
        XCTAssertEqual(options.limit, 8)
        XCTAssertEqual(options.benchmarkLogDir, "/tmp/logs")
        XCTAssertFalse(options.useCache)

        XCTAssertThrowsError(try WhispCLI.parseVisionBenchmarkOptions(args: [
            "--benchmark-vision-cases",
            "/tmp/manual.jsonl",
            "--unknown",
        ]))
    }

    func testParseSTTBenchmarkOptionsParsesAndRejectsInvalidMode() throws {
        let options = try WhispCLI.parseSTTBenchmarkOptions(args: [
            "--benchmark-stt-cases",
            "/tmp/manual.jsonl",
            "--stt", "rest",
            "--chunk-ms", "200",
            "--no-realtime",
            "--limit", "16",
            "--min-audio-seconds", "2.25",
            "--benchmark-log-dir", "/tmp/logs",
            "--no-cache",
        ])

        XCTAssertEqual(options.jsonlPath, "/tmp/manual.jsonl")
        XCTAssertEqual(options.sttMode, .rest)
        XCTAssertEqual(options.chunkMs, 200)
        XCTAssertFalse(options.realtime)
        XCTAssertEqual(options.limit, 16)
        XCTAssertEqual(options.minAudioSeconds, 2.25, accuracy: 0.0001)
        XCTAssertEqual(options.benchmarkLogDir, "/tmp/logs")
        XCTAssertFalse(options.useCache)

        XCTAssertThrowsError(try WhispCLI.parseSTTBenchmarkOptions(args: [
            "--benchmark-stt-cases",
            "/tmp/manual.jsonl",
            "--stt",
            "invalid",
        ]))
    }

    func testParseGenerationBenchmarkOptionsParsesAndRejectsUnknownOption() throws {
        let options = try WhispCLI.parseGenerationBenchmarkOptions(args: [
            "--benchmark-generation-cases",
            "/tmp/manual.jsonl",
            "--limit", "30",
            "--require-context",
            "--benchmark-log-dir", "/tmp/logs",
            "--no-cache",
        ])

        XCTAssertEqual(options.jsonlPath, "/tmp/manual.jsonl")
        XCTAssertEqual(options.limit, 30)
        XCTAssertTrue(options.requireContext)
        XCTAssertEqual(options.benchmarkLogDir, "/tmp/logs")
        XCTAssertFalse(options.useCache)

        XCTAssertThrowsError(try WhispCLI.parseGenerationBenchmarkOptions(args: [
            "--benchmark-generation-cases",
            "/tmp/manual.jsonl",
            "--unknown",
        ]))
    }
}
