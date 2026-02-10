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
}
