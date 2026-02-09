import XCTest
@testable import WhispCore

final class AudioMathTests: XCTestCase {
    func testF32ToI16Bounds() {
        XCTAssertEqual(f32ToI16(1.0), Int16.max)
        XCTAssertEqual(f32ToI16(-1.0), Int16.min + 1)
        XCTAssertEqual(f32ToI16(0.0), 0)
    }

    func testU16ToI16Center() {
        XCTAssertEqual(u16ToI16(32768), 0)
    }

    func testDownmixF32Average() {
        let stereo: [Float] = [1.0, -1.0, 0.5, 0.5]
        let mono = downmixF32(stereo, channels: 2)
        XCTAssertEqual(mono, [0.0, 0.5])
    }
}
