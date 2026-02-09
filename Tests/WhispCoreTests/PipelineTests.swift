import XCTest
@testable import WhispCore

final class PipelineTests: XCTestCase {
    func testIsEmptySTTTreatsWhitespaceAsEmpty() {
        XCTAssertTrue(isEmptySTT(""))
        XCTAssertTrue(isEmptySTT("   "))
        XCTAssertTrue(isEmptySTT("\n\t"))
        XCTAssertFalse(isEmptySTT("テスト"))
    }

    func testCollectAudioDrainsAllChunks() {
        let chunks = Array(repeating: [UInt8]([1, 2, 3, 4]), count: 32)
        let pcmData = collectAudio(chunks)
        XCTAssertEqual(pcmData.count, 32 * 4)
    }
}
