import Foundation
import WhispCore

extension WhispCLI {
    static func executePipelineRun(
        config: Config,
        options: PipelineOptions,
        context: ContextInfo?
    ) async throws -> PipelineRunResult {
        let sttCredential = try APIKeyResolver.sttCredential(config: config, preset: options.sttPreset)
        let model = APIKeyResolver.effectivePostProcessModel(config.llmModel)
        let llmKey = try APIKeyResolver.llmKey(config: config, model: model)

        let wavData = try Data(contentsOf: URL(fileURLWithPath: options.path))
        let audio = try parsePCM16MonoWAV(wavData)

        var sttText: String
        var sttSource: String
        var sttTotalMs: Double
        var sttAfterStopMs: Double
        var sttSendMs: Double
        var sttFinalizeMs: Double

        let wallStartedAt = DispatchTime.now()
        let sttResult = try await runSTTInference(
            preset: options.sttPreset,
            credential: sttCredential,
            audio: audio,
            languageHint: config.inputLanguage,
            chunkMs: options.chunkMs,
            realtime: options.realtime,
            segmentation: config.sttSegmentation
        )
        sttText = sttResult.transcript
        sttSource = options.sttMode.rawValue
        sttTotalMs = sttResult.totalMs
        sttAfterStopMs = sttResult.afterStopMs
        sttFinalizeMs = sttResult.afterStopMs
        sttSendMs = max(0, sttResult.totalMs - sttResult.afterStopMs)

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
