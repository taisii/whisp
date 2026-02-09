import XCTest
@testable import WhispCore

final class AudioFileTests: XCTestCase {
    func testParsePCM16MonoWAVRoundtrip() throws {
        var pcm = Data()
        for sample: Int16 in [0, 1024, -1024, 32767, -32768] {
            var v = sample.littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }

        let wav = buildWAVBytes(sampleRate: 16_000, pcmData: pcm)
        let parsed = try parsePCM16MonoWAV(wav)

        XCTAssertEqual(parsed.sampleRate, 16_000)
        XCTAssertEqual(parsed.pcmBytes, pcm)
        XCTAssertEqual(parsed.durationSeconds, Float(pcm.count) / Float(16_000 * 2), accuracy: 0.0001)
    }

    func testParsePCM16MonoWAVRejectsNonWAV() {
        XCTAssertThrowsError(try parsePCM16MonoWAV(Data("invalid".utf8)))
    }
}
