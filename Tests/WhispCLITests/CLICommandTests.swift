import XCTest
@testable import whisp

final class CLICommandTests: XCTestCase {
    func testParseSelfCheckCommand() throws {
        let command = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: ["--self-check"]))
        guard case .selfCheck = command else {
            return XCTFail("unexpected command")
        }
    }

    func testParseStreamCommandWithOptions() throws {
        let command = try XCTUnwrap(WhispCLI.CLICommand.parse(arguments: [
            "--stt-stream-file",
            "/tmp/in.wav",
            "--chunk-ms",
            "240",
            "--realtime",
        ]))

        guard case let .sttStream(options) = command else {
            return XCTFail("unexpected command")
        }
        XCTAssertEqual(options.path, "/tmp/in.wav")
        XCTAssertEqual(options.chunkMs, 240)
        XCTAssertTrue(options.realtime)
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
}
