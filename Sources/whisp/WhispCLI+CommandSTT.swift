import Foundation
import WhispCore

extension WhispCLI {
    static func runSTTFile(path: String) async throws {
        let config = try loadConfig()
        let key = try APIKeyResolver.sttKey(config: config, provider: .deepgram)

        let wavData = try Data(contentsOf: URL(fileURLWithPath: path))
        let audio = try parsePCM16MonoWAV(wavData)
        let client = DeepgramClient()
        let language = LanguageResolver.languageParam(config.inputLanguage)

        let startedAt = DispatchTime.now()
        let result = try await client.transcribe(
            apiKey: key,
            sampleRate: Int(audio.sampleRate),
            audio: audio.pcmBytes,
            language: language
        )
        let elapsed = elapsedMs(since: startedAt)

        print("mode: deepgram_rest")
        print("audio_seconds: \(String(format: "%.3f", audioDurationSeconds(audio: audio)))")
        print("total_ms: \(msString(elapsed))")
        print("transcript: \(result.transcript)")
        if let usage = result.usage {
            print("duration_seconds: \(usage.durationSeconds)")
            if let requestID = usage.requestID {
                print("request_id: \(requestID)")
            }
        }
    }

    static func runSTTStreamFile(path: String, chunkMs: Int, realtime: Bool) async throws {
        let config = try loadConfig()
        let key = try APIKeyResolver.sttKey(config: config, provider: .deepgram)

        let wavData = try Data(contentsOf: URL(fileURLWithPath: path))
        let audio = try parsePCM16MonoWAV(wavData)
        let sampleRate = Int(audio.sampleRate)
        let language = LanguageResolver.languageParam(config.inputLanguage)
        let client = DeepgramStreamingClient()

        let chunkSamples = max(1, sampleRate * chunkMs / 1000)
        let chunkBytes = chunkSamples * MemoryLayout<Int16>.size

        let startedAt = DispatchTime.now()
        try await client.start(apiKey: key, sampleRate: sampleRate, language: language)
        let streamStartedAt = DispatchTime.now()

        var offset = 0
        while offset < audio.pcmBytes.count {
            let end = min(offset + chunkBytes, audio.pcmBytes.count)
            let chunk = audio.pcmBytes.subdata(in: offset..<end)
            await client.enqueueAudioChunk(chunk)

            if realtime {
                let frameCount = (end - offset) / MemoryLayout<Int16>.size
                let seconds = Double(frameCount) / Double(sampleRate)
                let nanoseconds = UInt64(seconds * 1_000_000_000)
                if nanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                }
            }
            offset = end
        }

        let sendMs = elapsedMs(since: streamStartedAt)
        let finalizeStartedAt = DispatchTime.now()
        let result = try await client.finish()
        let finalizeMs = elapsedMs(since: finalizeStartedAt)
        let totalMs = elapsedMs(since: startedAt)

        print("mode: deepgram_stream")
        print("audio_seconds: \(String(format: "%.3f", audioDurationSeconds(audio: audio)))")
        print("chunk_ms: \(chunkMs)")
        print("realtime: \(realtime)")
        print("send_ms: \(msString(sendMs))")
        print("finalize_ms: \(msString(finalizeMs))")
        print("total_ms: \(msString(totalMs))")
        print("transcript: \(result.transcript)")
        if let usage = result.usage {
            print("duration_seconds: \(usage.durationSeconds)")
            if let requestID = usage.requestID {
                print("request_id: \(requestID)")
            }
        }
    }

    static func runPipelineFile(options: PipelineOptions) async throws {
        let config = try loadConfig()
        let context = try loadContextInfo(path: options.contextFilePath)
        let run = try await executePipelineRun(config: config, options: options, context: context)
        let dominant = dominantStage(sttAfterStopMs: run.sttAfterStopMs, postMs: run.postMs, outputMs: run.outputMs)

        print("mode: full_pipeline")
        print("stt_mode: \(options.sttMode.rawValue)")
        print("model: \(run.model.rawValue)")
        print("audio_seconds: \(String(format: "%.3f", run.audioSeconds))")
        print("stt_source: \(run.sttSource)")
        print("stt_send_ms: \(msString(run.sttSendMs))")
        print("stt_finalize_ms: \(msString(run.sttFinalizeMs))")
        print("stt_total_ms: \(msString(run.sttTotalMs))")
        print("stt_after_stop_ms: \(msString(run.sttAfterStopMs))")
        print("post_ms: \(msString(run.postMs))")
        print("output_ms: \(msString(run.outputMs))")
        print("total_after_stop_ms: \(msString(run.totalAfterStopMs))")
        print("total_wall_ms: \(msString(run.totalWallMs))")
        print("dominant_stage_after_stop: \(dominant)")
        print("stt_chars: \(run.sttText.count)")
        print("output_chars: \(run.outputText.count)")
        print("context_present: \(context != nil)")
        print("context_terms_count: \(context?.visionTerms.count ?? 0)")
        print("stt_sample: \(sampleText(run.sttText))")
        print("output_sample: \(sampleText(run.outputText))")
    }

}
