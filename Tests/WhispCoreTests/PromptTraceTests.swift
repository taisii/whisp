import XCTest
@testable import WhispCore

final class PromptTraceTests: XCTestCase {
    func testResolvedDirectoryPathUsesEnvironmentOverride() {
        let path = PromptTrace.resolvedDirectoryPath(environment: [
            "HOME": "/Users/tester",
            "WHISP_PROMPT_TRACE_DIR": "  /tmp/custom-prompts  ",
        ])
        XCTAssertEqual(path, "/tmp/custom-prompts")
    }

    func testResolvedDirectoryPathUsesDefaultRunsPathWhenOverrideMissing() {
        let path = PromptTrace.resolvedDirectoryPath(environment: [
            "HOME": "/Users/tester",
        ])
        XCTAssertEqual(path, "/Users/tester/.config/whisp/debug/runs/_default/prompts")
    }

    func testWriteResponseStoresTextAtResponsePath() throws {
        let runDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        let reference = PromptTrace.dump(
            stage: "postprocess",
            model: "gpt-5-nano",
            appName: nil,
            context: nil,
            prompt: "PROMPT",
            extra: ["run_dir": runDir.path]
        )
        XCTAssertNotNil(reference)

        PromptTrace.writeResponse("RESPONSE", usage: nil, reference: reference)
        let traceDirectoryPath = try XCTUnwrap(reference?.traceDirectoryPath)
        let request = try String(
            contentsOfFile: URL(fileURLWithPath: traceDirectoryPath)
                .appendingPathComponent("request.txt")
                .path,
            encoding: .utf8
        )
        let responsePath = try XCTUnwrap(reference?.responseTextFilePath)
        let response = try String(contentsOfFile: responsePath, encoding: .utf8)
        let responseMetaPath = try XCTUnwrap(reference?.responseMetaFilePath)
        let responseMetaData = try Data(contentsOf: URL(fileURLWithPath: responseMetaPath))
        let responseMeta = try JSONDecoder().decode(PromptTraceResponseRecord.self, from: responseMetaData)
        XCTAssertEqual(request, "PROMPT")
        XCTAssertEqual(response, "RESPONSE")
        XCTAssertEqual(responseMeta.status, .ok)
        XCTAssertEqual(responseMeta.responseChars, 8)
    }
}
