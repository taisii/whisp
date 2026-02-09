import XCTest
@testable import WhispCore

final class HotKeyTests: XCTestCase {
    func testParseSimpleShortcut() throws {
        let parsed = try parseHotKey("Cmd+J")
        XCTAssertEqual(parsed.keyCode, 0x26)
        XCTAssertEqual(parsed.modifiers & carbonCommandModifier, carbonCommandModifier)
    }

    func testParseMultipleModifiers() throws {
        let parsed = try parseHotKey("Ctrl+Alt+Shift+F1")
        XCTAssertEqual(parsed.keyCode, 0x7A)
        XCTAssertEqual(parsed.modifiers & carbonControlModifier, carbonControlModifier)
        XCTAssertEqual(parsed.modifiers & carbonOptionModifier, carbonOptionModifier)
        XCTAssertEqual(parsed.modifiers & carbonShiftModifier, carbonShiftModifier)
    }

    func testRejectModifierOnly() {
        XCTAssertThrowsError(try parseHotKey("Option"))
    }

    func testRejectUnsupportedKey() {
        XCTAssertThrowsError(try parseHotKey("Cmd+Fn"))
    }
}
