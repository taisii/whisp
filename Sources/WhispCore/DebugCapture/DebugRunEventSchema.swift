import Foundation

public enum DebugRunEventName: String, Codable, CaseIterable, Sendable {
    case recordingStart = "recording_start"
    case recordingStop = "recording_stop"
    case recordingSaved = "recording_saved"

    case sttStart = "stt_start"
    case sttDone = "stt_done"
    case sttStreamConnected = "stt_stream_connected"
    case sttStreamConnectFailed = "stt_stream_connect_failed"
    case sttStreamFinalizeStart = "stt_stream_finalize_start"
    case sttStreamFinalizeDone = "stt_stream_finalize_done"
    case sttStreamFailedFallbackREST = "stt_stream_failed_fallback_rest"
    case sttStreamChunksDrained = "stt_stream_chunks_drained"

    case visionDisabled = "vision_disabled"
    case visionSkippedMissingKey = "vision_skipped_missing_key"
    case visionStart = "vision_start"
    case visionDone = "vision_done"
    case visionSkippedNotReady = "vision_skipped_not_ready"
    case visionCollectFailed = "vision_collect_failed"

    case contextSummaryStart = "context_summary_start"
    case contextSummaryDone = "context_summary_done"
    case contextSummaryFailed = "context_summary_failed"
    case contextSummaryDisabled = "context_summary_disabled"
    case contextSummarySkippedNoSource = "context_summary_skipped_no_source"
    case contextSummarySkippedMissingKey = "context_summary_skipped_missing_key"
    case contextSummaryNotReadyContinue = "context_summary_not_ready_continue"

    case postprocessStart = "postprocess_start"
    case postprocessDone = "postprocess_done"
    case audioLLMStart = "audio_llm_start"
    case audioLLMDone = "audio_llm_done"
    case directInputDone = "direct_input_done"
    case pipelineDone = "pipeline_done"
    case pipelineError = "pipeline_error"
}

public enum DebugRunEventField: String, Codable, CaseIterable, Sendable {
    case mode
    case model
    case sttProvider = "stt_provider"
    case sttStreaming = "stt_streaming"
    case source
    case error

    case recordingStartedAtMs = "recording_started_at_ms"
    case recordingStoppedAtMs = "recording_stopped_at_ms"
    case requestSentAtMs = "request_sent_at_ms"
    case responseReceivedAtMs = "response_received_at_ms"

    case recordingMs = "recording_ms"
    case durationMs = "duration_ms"
    case waitMs = "wait_ms"
    case captureMs = "capture_ms"
    case analyzeMs = "analyze_ms"
    case totalMs = "total_ms"
    case pipelineMs = "pipeline_ms"
    case endToEndMs = "end_to_end_ms"
    case elapsedMs = "elapsed_ms"

    case sampleRate = "sample_rate"
    case audioBytes = "audio_bytes"
    case pcmBytes = "pcm_bytes"
    case textChars = "text_chars"
    case outputChars = "output_chars"
    case imageBytes = "image_bytes"
    case imageWH = "image_wh"
    case contextPresent = "context_present"
}

public enum DebugSTTSource: String, Codable, CaseIterable, Sendable {
    case rest
    case restFallback = "rest_fallback"
    case whisper
    case whisperREST = "whisper_rest"
    case appleSpeech = "apple_speech"
}

public extension DebugRunEvent {
    var name: DebugRunEventName? {
        DebugRunEventName(rawValue: event)
    }

    func field(_ key: DebugRunEventField) -> String? {
        fields[key.rawValue]
    }
}
