import Foundation
import XCTest
@testable import WhispCore

final class OpenAIRealtimeSessionPayloadTests: XCTestCase {
    func testSessionUpdatePayloadUsesTranscriptionSchema() throws {
        let payloadData = try OpenAIRealtimeStreamingClient.makeSessionUpdatePayload(
            transcriptionModel: "gpt-4o-mini-transcribe",
            sampleRate: 24_000
        )
        let payload = try JSONDecoder().decode(SessionUpdatePayload.self, from: payloadData)

        XCTAssertEqual(payload.type, "session.update")
        XCTAssertEqual(payload.session.type, "transcription")
        XCTAssertEqual(payload.session.audio.input.format.type, "audio/pcm")
        XCTAssertEqual(payload.session.audio.input.format.rate, 24_000)
        XCTAssertEqual(payload.session.audio.input.transcription.model, "gpt-4o-mini-transcribe")
        XCTAssertEqual(payload.session.audio.input.turnDetection.type, "server_vad")
    }

    func testSessionUpdatePayloadOmitsLegacyKeys() throws {
        let payloadData = try OpenAIRealtimeStreamingClient.makeSessionUpdatePayload(
            transcriptionModel: "gpt-4o-mini-transcribe",
            sampleRate: 24_000
        )
        let payloadText = try XCTUnwrap(String(data: payloadData, encoding: .utf8))

        XCTAssertFalse(payloadText.contains("input_audio_format"))
        XCTAssertFalse(payloadText.contains("input_audio_transcription"))
    }

    func testRealtimeURLUsesTranscriptionModelByDefault() throws {
        let url = try XCTUnwrap(
            OpenAIRealtimeStreamingClient.makeRealtimeURL(
                model: OpenAIRealtimeStreamingClient.defaultTranscriptionModel
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let modelQuery = components.queryItems?.first(where: { $0.name == "model" })?.value

        XCTAssertEqual(modelQuery, "gpt-4o-mini-transcribe")
    }
}

private struct SessionUpdatePayload: Decodable {
    let type: String
    let session: Session

    struct Session: Decodable {
        let type: String
        let audio: Audio
    }

    struct Audio: Decodable {
        let input: Input
    }

    struct Input: Decodable {
        let format: Format
        let transcription: Transcription
        let turnDetection: TurnDetection

        enum CodingKeys: String, CodingKey {
            case format
            case transcription
            case turnDetection = "turn_detection"
        }
    }

    struct Format: Decodable {
        let type: String
        let rate: Int
    }

    struct Transcription: Decodable {
        let model: String
    }

    struct TurnDetection: Decodable {
        let type: String
    }
}
