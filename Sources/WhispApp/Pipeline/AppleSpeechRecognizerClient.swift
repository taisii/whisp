import Foundation
import WhispCore

final class AppleSpeechRecognizerClient: AppleSpeechTranscriber, @unchecked Sendable {
    private let backend: AppleSpeechClient

    init(backend: AppleSpeechClient = AppleSpeechClient()) {
        self.backend = backend
    }

    func transcribe(
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> (transcript: String, usage: STTUsage?) {
        try await backend.transcribe(sampleRate: sampleRate, audio: audio, language: language)
    }

    func startStreaming(
        sampleRate: Int,
        language: String?
    ) async throws {
        try await backend.startStreaming(sampleRate: sampleRate, language: language)
    }

    func enqueueStreamingAudioChunk(_ chunk: Data) async {
        await backend.enqueueStreamingAudioChunk(chunk)
    }

    func finishStreaming() async throws -> (transcript: String, usage: STTUsage?) {
        try await backend.finishStreaming()
    }
}
