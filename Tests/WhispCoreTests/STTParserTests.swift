import XCTest
@testable import WhispCore

final class STTParserTests: XCTestCase {
    func testParsePartialTranscript() {
        let payload = """
        {
          "channel": { "alternatives": [ { "transcript": "hello" } ] },
          "is_final": false
        }
        """
        let chunk = parseDeepgramMessage(payload)
        XCTAssertEqual(chunk, TranscriptChunk(text: "hello", isFinal: false))
    }

    func testParseFinalTranscript() {
        let payload = """
        {
          "channel": { "alternatives": [ { "transcript": "world" } ] },
          "is_final": true
        }
        """
        let chunk = parseDeepgramMessage(payload)
        XCTAssertEqual(chunk?.isFinal, true)
        XCTAssertEqual(chunk?.text, "world")
    }

    func testParseTranscriptWithDuration() {
        let payload = """
        {
          "channel": { "alternatives": [ { "transcript": "hello" } ] },
          "is_final": true,
          "duration": 5.25
        }
        """
        let parsed = parseDeepgramMessageWithDuration(payload)
        XCTAssertEqual(parsed?.chunk.isFinal, true)
        XCTAssertEqual(parsed?.chunk.text, "hello")
        XCTAssertEqual(parsed?.duration ?? 0, 5.25, accuracy: 0.001)
        XCTAssertNil(parsed?.requestID)
    }

    func testParseTranscriptWithoutDuration() {
        let payload = """
        {
          "channel": { "alternatives": [ { "transcript": "test" } ] },
          "is_final": false
        }
        """
        let parsed = parseDeepgramMessageWithDuration(payload)
        XCTAssertEqual(parsed?.chunk.isFinal, false)
        XCTAssertEqual(parsed?.duration ?? 0, 0, accuracy: 0.001)
        XCTAssertNil(parsed?.requestID)
    }

    func testParseMetadataDurationAndRequestID() {
        let payload = """
        {
          "channel": { "alternatives": [ { "transcript": "hello" } ] },
          "is_final": true,
          "metadata": {
            "duration": 3.5,
            "request_id": "abc123"
          }
        }
        """
        let parsed = parseDeepgramMessageWithDuration(payload)
        XCTAssertEqual(parsed?.chunk.isFinal, true)
        XCTAssertEqual(parsed?.chunk.text, "hello")
        XCTAssertEqual(parsed?.duration ?? 0, 3.5, accuracy: 0.001)
        XCTAssertEqual(parsed?.requestID, "abc123")
    }

    func testParseAlternativeWithExtraFields() {
        let payload = """
        {
          "channel": { "alternatives": [ { "transcript": "hello", "confidence": 0.99 } ] },
          "is_final": true
        }
        """
        let chunk = parseDeepgramMessage(payload)
        XCTAssertEqual(chunk?.text, "hello")
        XCTAssertEqual(chunk?.isFinal, true)
    }
}
