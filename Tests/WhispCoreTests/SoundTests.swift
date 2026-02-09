import XCTest
@testable import WhispCore

final class SoundTests: XCTestCase {
    func testTinkPathIsSystemSound() {
        XCTAssertEqual(tinkPath, "/System/Library/Sounds/Tink.aiff")
    }
}
