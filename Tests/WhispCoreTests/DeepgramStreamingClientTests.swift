import Foundation
import XCTest
@testable import WhispCore

final class DeepgramStreamingClientTests: XCTestCase {
    func testListenURLIncludesEndpointingAndInterimResults() throws {
        let url = try XCTUnwrap(DeepgramStreamingClient.makeListenURL(sampleRate: 16_000, language: "ja"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(query["sample_rate"], "16000")
        XCTAssertEqual(query["endpointing"], "300")
        XCTAssertEqual(query["interim_results"], "true")
        XCTAssertEqual(query["language"], "ja")
    }

    func testShouldSendKeepAliveWhenIdleDurationExceedsThreshold() {
        XCTAssertTrue(DeepgramStreamingClient.shouldSendKeepAlive(idleDurationMs: 4_000))
        XCTAssertTrue(DeepgramStreamingClient.shouldSendKeepAlive(idleDurationMs: 4_500))
    }

    func testShouldNotSendKeepAliveWhenIdleDurationIsBelowThreshold() {
        XCTAssertFalse(DeepgramStreamingClient.shouldSendKeepAlive(idleDurationMs: 3_900))
    }
}
