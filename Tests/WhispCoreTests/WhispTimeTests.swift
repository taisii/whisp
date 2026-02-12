import XCTest
@testable import WhispCore

final class WhispTimeTests: XCTestCase {
    func testISOFormatIncludesFractionalSeconds() {
        let now = WhispTime.isoNow()
        XCTAssertTrue(now.contains("T"))
        XCTAssertTrue(now.contains("."))
        XCTAssertTrue(now.hasSuffix("Z"))
    }

    func testTimestampTokens() {
        let withMillis = WhispTime.timestampTokenWithMillis()
        let seconds = WhispTime.timestampTokenSeconds()
        XCTAssertEqual(withMillis.count, 19)
        XCTAssertEqual(seconds.count, 15)
        XCTAssertTrue(withMillis.contains("-"))
        XCTAssertTrue(seconds.contains("-"))
    }

    func testEpochMsHelpers() {
        let date = Date(timeIntervalSince1970: 1.234)
        XCTAssertEqual(WhispTime.epochMs(date), 1234)
        XCTAssertEqual(WhispTime.epochMsString(date), "1234.000")
    }
}
