import XCTest
@testable import WhispCore

final class ShortcutTests: XCTestCase {
    func testBuildShortcutWithCommandModifier() {
        XCTAssertEqual(buildShortcutString(ShortcutInput(key: "j", metaKey: true)), "Cmd+J")
    }

    func testBuildShortcutWithMultipleModifiers() {
        let input = ShortcutInput(key: "k", ctrlKey: true, altKey: true, shiftKey: true)
        XCTAssertEqual(buildShortcutString(input), "Ctrl+Alt+Shift+K")
    }

    func testNormalizeSpecialKeys() {
        XCTAssertEqual(buildShortcutString(ShortcutInput(key: " ", altKey: true)), "Alt+Space")
        XCTAssertEqual(buildShortcutString(ShortcutInput(key: "ArrowUp", shiftKey: true)), "Shift+Up")
    }

    func testAcceptFunctionKeys() {
        XCTAssertEqual(buildShortcutString(ShortcutInput(key: "F1", ctrlKey: true)), "Ctrl+F1")
        XCTAssertEqual(buildShortcutString(ShortcutInput(key: "f12", metaKey: true)), "Cmd+F12")
    }

    func testRejectFnKey() {
        XCTAssertNil(buildShortcutString(ShortcutInput(key: "Fn", metaKey: true)))
    }

    func testFormatShortcutDisplay() {
        XCTAssertEqual(formatShortcutDisplay("Cmd+J"), "⌘ J")
        XCTAssertEqual(formatShortcutDisplay("Ctrl+Alt+Shift+F1"), "⌃ ⌥ ⇧ F1")
    }

    func testFormatShortcutDisplayHandlesEmpty() {
        XCTAssertEqual(formatShortcutDisplay(""), "-")
    }
}
