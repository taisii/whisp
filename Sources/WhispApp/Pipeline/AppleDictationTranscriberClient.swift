import AVFoundation
import Foundation
import Speech
import WhispCore

final class AppleDictationTranscriberClient: AppleSpeechTranscriber, @unchecked Sendable {
    private struct StreamingState {
        let sampleRate: Int
        let language: String?
        var audio: Data
    }

    private actor StreamingStore {
        private var state: StreamingState?

        func start(sampleRate: Int, language: String?) {
            state = StreamingState(sampleRate: sampleRate, language: language, audio: Data())
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty, var current = state else {
                return
            }
            current.audio.append(chunk)
            state = current
        }

        func finish() -> StreamingState? {
            defer { state = nil }
            return state
        }
    }

    private let streamingStore = StreamingStore()

    func transcribe(
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> (transcript: String, usage: STTUsage?) {
        try assertAvailable()
        guard !audio.isEmpty else {
            return ("", nil)
        }

        let normalizedSampleRate = max(sampleRate, 1)
        let transcript = try await transcribeModern(
            sampleRate: normalizedSampleRate,
            audio: audio,
            language: language
        )
        let duration = Double(audio.count) / Double(normalizedSampleRate * MemoryLayout<Int16>.size)
        let usage = duration > 0
            ? STTUsage(
                durationSeconds: duration,
                requestID: nil,
                provider: STTProvider.appleSpeech.rawValue
            )
            : nil
        return (transcript, usage)
    }

    func startStreaming(
        sampleRate: Int,
        language: String?
    ) async throws {
        try assertAvailable()
        await streamingStore.start(sampleRate: max(sampleRate, 1), language: language)
    }

    func enqueueStreamingAudioChunk(_ chunk: Data) async {
        await streamingStore.append(chunk)
    }

    func finishStreaming() async throws -> (transcript: String, usage: STTUsage?) {
        guard let state = await streamingStore.finish() else {
            throw AppError.invalidArgument("Apple Dictation Transcriber streaming セッションが開始されていません")
        }

        return try await transcribe(
            sampleRate: state.sampleRate,
            audio: state.audio,
            language: state.language
        )
    }

    private func assertAvailable() throws {
#if os(macOS)
        if #available(macOS 26.0, *) {
            return
        }
        throw AppError.invalidArgument("Apple Dictation Transcriber は macOS 26 以降で利用できます")
#else
        throw AppError.invalidArgument("Apple Dictation Transcriber はこのOSで利用できません")
#endif
    }

    private func transcribeModern(
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> String {
#if os(macOS)
        if #available(macOS 26.0, *) {
            return try await transcribeModernAvailable(
                sampleRate: sampleRate,
                audio: audio,
                language: language
            )
        }
        throw AppError.invalidArgument("Apple Dictation Transcriber は macOS 26 以降で利用できます")
#else
        throw AppError.invalidArgument("Apple Dictation Transcriber はこのOSで利用できません")
#endif
    }

#if os(macOS)
    @available(macOS 26.0, *)
    private func transcribeModernAvailable(
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> String {
        let locale = localeForLanguage(language)
        let module = DictationTranscriber(locale: locale, preset: .longDictation)
        return try await transcribeWithSpeechModule(
            sampleRate: sampleRate,
            audio: audio,
            module: module
        ) { result in
            String(result.text.characters)
        }
    }

    @available(macOS 26.0, *)
    private func transcribeWithSpeechModule<Module: SpeechModule>(
        sampleRate: Int,
        audio: Data,
        module: Module,
        extractText: @escaping @Sendable (Module.Result) -> String
    ) async throws -> String {
        let wavData = buildWAVBytes(sampleRate: UInt32(sampleRate), pcmData: audio)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisp-apple-dictation-transcriber-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try wavData.write(to: tmpURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let audioFile = try AVAudioFile(forReading: tmpURL)
        let analyzer = SpeechAnalyzer(modules: [module])

        let resultsTask = Task<[String], Error> {
            var parts: [String] = []
            for try await result in module.results {
                let text = extractText(result).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    parts.append(text)
                }
            }
            return parts
        }

        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        } catch {
            resultsTask.cancel()
            throw AppError.io("Apple Dictation Transcriber 文字起こしに失敗: \(error.localizedDescription)")
        }

        let parts = try await resultsTask.value
        return normalizedTranscript(parts: parts)
    }
#endif

    private func localeForLanguage(_ language: String?) -> Locale {
        switch language {
        case "ja":
            return Locale(identifier: "ja-JP")
        case "en":
            return Locale(identifier: "en-US")
        case .some(let value):
            return Locale(identifier: value)
        case .none:
            return Locale.current
        }
    }

    private func normalizedTranscript(parts: [String]) -> String {
        var normalized: [String] = []
        normalized.reserveCapacity(parts.count)
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            if normalized.last == trimmed {
                continue
            }
            normalized.append(trimmed)
        }
        return normalized.joined(separator: "\n")
    }
}
