import Foundation
import WhispCore

final class AppleSpeechAnalyzerClient: AppleSpeechTranscriber, @unchecked Sendable {
    private let recognizerClient: AppleSpeechRecognizerClient

    init(recognizerClient: AppleSpeechRecognizerClient = AppleSpeechRecognizerClient()) {
        self.recognizerClient = recognizerClient
    }

    func transcribe(
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> (transcript: String, usage: STTUsage?) {
        try await recognizerClient.transcribe(sampleRate: sampleRate, audio: audio, language: language)
    }

    func startStreaming(
        sampleRate: Int,
        language: String?
    ) async throws {
        try await recognizerClient.startStreaming(sampleRate: sampleRate, language: language)
    }

    func enqueueStreamingAudioChunk(_ chunk: Data) async {
        await recognizerClient.enqueueStreamingAudioChunk(chunk)
    }

    func finishStreaming() async throws -> (transcript: String, usage: STTUsage?) {
        try await recognizerClient.finishStreaming()
    }
}
