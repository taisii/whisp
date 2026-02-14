import Foundation
import WhispCore

extension WhispCLI {
    static func executePipelineRun(
        config: Config,
        options: PipelineOptions,
        context: ContextInfo?
    ) async throws -> PipelineRunResult {
        let sttCredential = try APIKeyResolver.sttCredential(config: config, provider: .deepgram)
        guard case let .apiKey(deepgramKey) = sttCredential else {
            throw AppError.invalidArgument("Deepgram APIキーが未設定です")
        }
        let model = APIKeyResolver.effectivePostProcessModel(config.llmModel)
        let llmKey = try APIKeyResolver.llmKey(config: config, model: model)

        let wavData = try Data(contentsOf: URL(fileURLWithPath: options.path))
        let audio = try parsePCM16MonoWAV(wavData)
        let sampleRate = Int(audio.sampleRate)
        let language = LanguageResolver.languageParam(config.inputLanguage)

        var sttText = ""
        var sttSource = ""
        var sttTotalMs = 0.0
        var sttAfterStopMs = 0.0
        var sttSendMs = 0.0
        var sttFinalizeMs = 0.0

        let wallStartedAt = DispatchTime.now()

        switch options.sttMode {
        case .rest:
            let sttStartedAt = DispatchTime.now()
            let result = try await DeepgramClient().transcribe(
                apiKey: deepgramKey,
                sampleRate: sampleRate,
                audio: audio.pcmBytes,
                language: language
            )
            sttText = result.transcript
            sttSource = "rest"
            sttTotalMs = elapsedMs(since: sttStartedAt)
            sttAfterStopMs = sttTotalMs
            sttFinalizeMs = sttTotalMs
        case .stream:
            let stream = DeepgramStreamingClient()
            let chunkSamples = max(1, sampleRate * options.chunkMs / 1000)
            let chunkBytes = chunkSamples * MemoryLayout<Int16>.size

            try await stream.start(apiKey: deepgramKey, sampleRate: sampleRate, language: language)
            let sendStartedAt = DispatchTime.now()
            var offset = 0
            while offset < audio.pcmBytes.count {
                let end = min(offset + chunkBytes, audio.pcmBytes.count)
                await stream.enqueueAudioChunk(audio.pcmBytes.subdata(in: offset..<end))

                if options.realtime {
                    let frameCount = (end - offset) / MemoryLayout<Int16>.size
                    let seconds = Double(frameCount) / Double(sampleRate)
                    let nanoseconds = UInt64(seconds * 1_000_000_000)
                    if nanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: nanoseconds)
                    }
                }
                offset = end
            }
            sttSendMs = elapsedMs(since: sendStartedAt)

            let finalizeStartedAt = DispatchTime.now()
            let result = try await stream.finish()
            sttFinalizeMs = elapsedMs(since: finalizeStartedAt)

            sttText = result.transcript
            sttSource = "stream"
            sttTotalMs = sttSendMs + sttFinalizeMs
            sttAfterStopMs = sttFinalizeMs
        }

        let postStartedAt = DispatchTime.now()
        let postResult = try await postProcessText(
            model: model,
            apiKey: llmKey,
            config: config,
            sttText: sttText,
            context: context,
            sttMode: options.sttMode.rawValue
        )
        let postMs = elapsedMs(since: postStartedAt)

        let outputStartedAt = DispatchTime.now()
        try emitResult(postResult.text, mode: options.emitMode)
        let outputMs = elapsedMs(since: outputStartedAt)

        let totalAfterStopMs = sttAfterStopMs + postMs + outputMs
        let totalWallMs = elapsedMs(since: wallStartedAt)
        return PipelineRunResult(
            model: model,
            sttText: sttText,
            outputText: postResult.text,
            sttSource: sttSource,
            sttSendMs: sttSendMs,
            sttFinalizeMs: sttFinalizeMs,
            sttTotalMs: sttTotalMs,
            sttAfterStopMs: sttAfterStopMs,
            postMs: postMs,
            outputMs: outputMs,
            totalAfterStopMs: totalAfterStopMs,
            totalWallMs: totalWallMs,
            audioSeconds: audioDurationSeconds(audio: audio)
        )
    }
}
