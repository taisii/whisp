import XCTest
@testable import WhispCore

final class LanguageResolverTests: XCTestCase {
    func testLanguageParamResolvesSupportedValues() {
        XCTAssertNil(LanguageResolver.languageParam("auto"))
        XCTAssertEqual(LanguageResolver.languageParam("ja"), "ja")
        XCTAssertEqual(LanguageResolver.languageParam("en"), "en")
        XCTAssertNil(LanguageResolver.languageParam("unknown"))
    }
}
