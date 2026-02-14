import XCTest
@testable import whisp

final class CLICommandTests: XCTestCase {
    func testParseDebugSelfCheckCommand() throws {
        XCTAssertNoThrow(try WhispCLI.parseAsRoot(["debug", "self-check"]))
    }

    func testParseDebugBenchmarkStatusCommand() throws {
        let parsed = try DebugBenchmarkStatusCommand.parseAsRoot([
            "--cases", "/tmp/manual.jsonl",
            "--format", "json",
        ])
        guard let command = parsed as? DebugBenchmarkStatusCommand else {
            return XCTFail("unexpected command type")
        }
        XCTAssertEqual(command.cases, "/tmp/manual.jsonl")
        XCTAssertEqual(command.format, .json)
    }

    func testParseDebugBenchmarkIntegrityCommand() throws {
        let parsed = try DebugBenchmarkIntegrityCommand.parseAsRoot([
            "--task", "stt",
            "--cases", "/tmp/manual.jsonl",
        ])
        guard let command = parsed as? DebugBenchmarkIntegrityCommand else {
            return XCTFail("unexpected command type")
        }
        XCTAssertEqual(command.task, .stt)
        XCTAssertEqual(command.cases, "/tmp/manual.jsonl")
        XCTAssertEqual(command.format, .text)
    }

    func testParseDebugBenchmarkIntegrityCommandRejectsUnknownTask() {
        XCTAssertThrowsError(try DebugBenchmarkIntegrityCommand.parseAsRoot([
            "--task", "vision",
            "--cases", "/tmp/manual.jsonl",
        ]))
    }

    func testOldTopLevelFlagsAreRejected() {
        XCTAssertThrowsError(try WhispCLI.parseAsRoot(["--self-check"]))
        XCTAssertThrowsError(try WhispCLI.parseAsRoot(["--benchmark-compare"]))
    }

    func testSelfCheckRunSucceeds() async throws {
        var command = DebugSelfCheckCommand()
        try await command.run()
    }

    func testLoadCasesCountForStatusReturnsNilForMalformedJSONL() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try "not-json\n".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let count = loadCasesCountForStatus(path: tempFile.path)
        XCTAssertNil(count)
    }

    func testLoadCasesCountForStatusReturnsCountForValidJSONL() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try """
        {"id":"c1","audio_file":"/tmp/a.wav"}
        {"id":"c2","audio_file":"/tmp/b.wav"}
        """.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let count = loadCasesCountForStatus(path: tempFile.path)
        XCTAssertEqual(count, 2)
    }
}
