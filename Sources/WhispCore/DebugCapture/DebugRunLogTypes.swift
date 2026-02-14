import Foundation

public enum DebugLogType: String, Codable, CaseIterable, Sendable {
    case recording
    case stt
    case vision
    case postprocess
    case directInput = "direct_input"
    case pipeline
    case contextSummary = "context_summary"
}

public enum DebugLogStatus: String, Codable, CaseIterable, Sendable {
    case ok
    case error
    case cancelled
    case skipped
}

public struct DebugRunLogBase: Equatable, Sendable {
    public let runID: String
    public let captureID: String?
    public let logType: DebugLogType
    public let eventStartMs: Int64
    public let eventEndMs: Int64
    public let recordedAtMs: Int64
    public let status: DebugLogStatus

    public init(
        runID: String,
        captureID: String?,
        logType: DebugLogType,
        eventStartMs: Int64,
        eventEndMs: Int64,
        recordedAtMs: Int64,
        status: DebugLogStatus
    ) {
        self.runID = runID
        self.captureID = captureID
        self.logType = logType
        self.eventStartMs = eventStartMs
        self.eventEndMs = eventEndMs
        self.recordedAtMs = recordedAtMs
        self.status = status
    }
}

public enum DebugSTTRoute: String, Codable, CaseIterable, Sendable {
    case streaming
    case rest
    case streamingFallbackREST = "streaming_fallback_rest"
    case onDevice = "on_device"
}

public enum DebugSTTAttemptKind: String, Codable, CaseIterable, Sendable {
    case streamFinalize = "stream_finalize"
    case restFallback = "rest_fallback"
    case rest
    case whisperREST = "whisper_rest"
    case appleSpeech = "apple_speech"
}

public struct DebugSTTAttempt: Codable, Equatable, Sendable {
    public let kind: DebugSTTAttemptKind
    public let status: DebugLogStatus
    public let eventStartMs: Int64
    public let eventEndMs: Int64
    public let source: String?
    public let error: String?
    public let textChars: Int?
    public let sampleRate: Int?
    public let audioBytes: Int?
    public let submittedChunks: Int?
    public let submittedBytes: Int?
    public let droppedChunks: Int?

    enum CodingKeys: String, CodingKey {
        case kind
        case status
        case eventStartMs = "event_start_ms"
        case eventEndMs = "event_end_ms"
        case source
        case error
        case textChars = "text_chars"
        case sampleRate = "sample_rate"
        case audioBytes = "audio_bytes"
        case submittedChunks = "submitted_chunks"
        case submittedBytes = "submitted_bytes"
        case droppedChunks = "dropped_chunks"
    }

    public init(
        kind: DebugSTTAttemptKind,
        status: DebugLogStatus,
        eventStartMs: Int64,
        eventEndMs: Int64,
        source: String? = nil,
        error: String? = nil,
        textChars: Int? = nil,
        sampleRate: Int? = nil,
        audioBytes: Int? = nil,
        submittedChunks: Int? = nil,
        submittedBytes: Int? = nil,
        droppedChunks: Int? = nil
    ) {
        self.kind = kind
        self.status = status
        self.eventStartMs = eventStartMs
        self.eventEndMs = eventEndMs
        self.source = source
        self.error = error
        self.textChars = textChars
        self.sampleRate = sampleRate
        self.audioBytes = audioBytes
        self.submittedChunks = submittedChunks
        self.submittedBytes = submittedBytes
        self.droppedChunks = droppedChunks
    }
}

public enum DebugPostProcessKind: String, Codable, CaseIterable, Sendable {
    case textPostprocess = "text_postprocess"
    case audioTranscribe = "audio_transcribe"
}

public struct DebugRecordingLog: Equatable, Sendable {
    public let base: DebugRunLogBase
    public let mode: String
    public let model: String
    public let sttProvider: String
    public let sttStreaming: Bool
    public let visionEnabled: Bool
    public let accessibilitySummaryStarted: Bool
    public let sampleRate: Int
    public let pcmBytes: Int

    public init(
        base: DebugRunLogBase,
        mode: String,
        model: String,
        sttProvider: String,
        sttStreaming: Bool,
        visionEnabled: Bool,
        accessibilitySummaryStarted: Bool,
        sampleRate: Int,
        pcmBytes: Int
    ) {
        self.base = base
        self.mode = mode
        self.model = model
        self.sttProvider = sttProvider
        self.sttStreaming = sttStreaming
        self.visionEnabled = visionEnabled
        self.accessibilitySummaryStarted = accessibilitySummaryStarted
        self.sampleRate = sampleRate
        self.pcmBytes = pcmBytes
    }
}

public struct DebugSTTLog: Equatable, Sendable {
    public let base: DebugRunLogBase
    public let provider: String
    public let transport: STTTransport
    public let route: DebugSTTRoute
    public let source: String
    public let textChars: Int
    public let sampleRate: Int
    public let audioBytes: Int
    public let attempts: [DebugSTTAttempt]

    public init(
        base: DebugRunLogBase,
        provider: String,
        transport: STTTransport,
        route: DebugSTTRoute,
        source: String,
        textChars: Int,
        sampleRate: Int,
        audioBytes: Int,
        attempts: [DebugSTTAttempt]
    ) {
        self.base = base
        self.provider = provider
        self.transport = transport
        self.route = route
        self.source = source
        self.textChars = textChars
        self.sampleRate = sampleRate
        self.audioBytes = audioBytes
        self.attempts = attempts
    }
}

public struct DebugVisionLog: Equatable, Sendable {
    public let base: DebugRunLogBase
    public let model: String
    public let mode: String
    public let contextPresent: Bool
    public let imageBytes: Int
    public let imageWidth: Int
    public let imageHeight: Int
    public let error: String?

    public init(
        base: DebugRunLogBase,
        model: String,
        mode: String,
        contextPresent: Bool,
        imageBytes: Int,
        imageWidth: Int,
        imageHeight: Int,
        error: String?
    ) {
        self.base = base
        self.model = model
        self.mode = mode
        self.contextPresent = contextPresent
        self.imageBytes = imageBytes
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.error = error
    }
}

public struct DebugPostProcessLog: Equatable, Sendable {
    public let base: DebugRunLogBase
    public let model: String
    public let contextPresent: Bool
    public let sttChars: Int
    public let outputChars: Int
    public let kind: DebugPostProcessKind

    public init(
        base: DebugRunLogBase,
        model: String,
        contextPresent: Bool,
        sttChars: Int,
        outputChars: Int,
        kind: DebugPostProcessKind
    ) {
        self.base = base
        self.model = model
        self.contextPresent = contextPresent
        self.sttChars = sttChars
        self.outputChars = outputChars
        self.kind = kind
    }
}

public struct DebugDirectInputLog: Equatable, Sendable {
    public let base: DebugRunLogBase
    public let success: Bool
    public let outputChars: Int

    public init(base: DebugRunLogBase, success: Bool, outputChars: Int) {
        self.base = base
        self.success = success
        self.outputChars = outputChars
    }
}

public struct DebugPipelineLog: Equatable, Sendable {
    public let base: DebugRunLogBase
    public let sttChars: Int
    public let outputChars: Int
    public let error: String?

    public init(base: DebugRunLogBase, sttChars: Int, outputChars: Int, error: String?) {
        self.base = base
        self.sttChars = sttChars
        self.outputChars = outputChars
        self.error = error
    }
}

public struct DebugContextSummaryLog: Equatable, Sendable {
    public let base: DebugRunLogBase
    public let source: String
    public let appName: String?
    public let sourceChars: Int
    public let summaryChars: Int
    public let termsCount: Int
    public let error: String?

    public init(
        base: DebugRunLogBase,
        source: String,
        appName: String?,
        sourceChars: Int,
        summaryChars: Int,
        termsCount: Int,
        error: String?
    ) {
        self.base = base
        self.source = source
        self.appName = appName
        self.sourceChars = sourceChars
        self.summaryChars = summaryChars
        self.termsCount = termsCount
        self.error = error
    }
}

public enum DebugRunLog: Equatable, Sendable {
    case recording(DebugRecordingLog)
    case stt(DebugSTTLog)
    case vision(DebugVisionLog)
    case postprocess(DebugPostProcessLog)
    case directInput(DebugDirectInputLog)
    case pipeline(DebugPipelineLog)
    case contextSummary(DebugContextSummaryLog)
}

public extension DebugRunLog {
    var base: DebugRunLogBase {
        switch self {
        case let .recording(log):
            return log.base
        case let .stt(log):
            return log.base
        case let .vision(log):
            return log.base
        case let .postprocess(log):
            return log.base
        case let .directInput(log):
            return log.base
        case let .pipeline(log):
            return log.base
        case let .contextSummary(log):
            return log.base
        }
    }
}

extension DebugRunLog: Codable {
    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case captureID = "capture_id"
        case stage
        case status
        case startedAtMs = "started_at_ms"
        case endedAtMs = "ended_at_ms"
        case recordedAtMs = "recorded_at_ms"
        case attrs
    }

    private enum AttrKeys: String, CodingKey {
        case mode
        case model
        case sttProvider = "stt_provider"
        case sttStreaming = "stt_streaming"
        case visionEnabled = "vision_enabled"
        case accessibilitySummaryStarted = "accessibility_summary_started"
        case sampleRate = "sample_rate"
        case pcmBytes = "pcm_bytes"

        case provider
        case transport
        case route
        case source
        case textChars = "text_chars"
        case audioBytes = "audio_bytes"
        case attempts

        case contextPresent = "context_present"
        case imageBytes = "image_bytes"
        case imageWidth = "image_width"
        case imageHeight = "image_height"
        case error

        case sttChars = "stt_chars"
        case outputChars = "output_chars"
        case kind

        case success

        case appName = "app_name"
        case sourceChars = "source_chars"
        case summaryChars = "summary_chars"
        case termsCount = "terms_count"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let logType = try container.decode(DebugLogType.self, forKey: .stage)
        let base = try DebugRunLogBase(
            runID: container.decode(String.self, forKey: .runID),
            captureID: container.decodeIfPresent(String.self, forKey: .captureID),
            logType: logType,
            eventStartMs: container.decode(Int64.self, forKey: .startedAtMs),
            eventEndMs: container.decode(Int64.self, forKey: .endedAtMs),
            recordedAtMs: container.decode(Int64.self, forKey: .recordedAtMs),
            status: container.decode(DebugLogStatus.self, forKey: .status)
        )
        let attrs = try container.nestedContainer(keyedBy: AttrKeys.self, forKey: .attrs)

        switch logType {
        case .recording:
            self = .recording(DebugRecordingLog(
                base: base,
                mode: try attrs.decode(String.self, forKey: .mode),
                model: try attrs.decode(String.self, forKey: .model),
                sttProvider: try attrs.decode(String.self, forKey: .sttProvider),
                sttStreaming: try attrs.decode(Bool.self, forKey: .sttStreaming),
                visionEnabled: try attrs.decode(Bool.self, forKey: .visionEnabled),
                accessibilitySummaryStarted: try attrs.decode(Bool.self, forKey: .accessibilitySummaryStarted),
                sampleRate: try attrs.decode(Int.self, forKey: .sampleRate),
                pcmBytes: try attrs.decode(Int.self, forKey: .pcmBytes)
            ))
        case .stt:
            let route = try attrs.decode(DebugSTTRoute.self, forKey: .route)
            let transport = try attrs.decodeIfPresent(STTTransport.self, forKey: .transport)
                ?? Self.fallbackTransport(for: route)
            self = .stt(DebugSTTLog(
                base: base,
                provider: try attrs.decode(String.self, forKey: .provider),
                transport: transport,
                route: route,
                source: try attrs.decode(String.self, forKey: .source),
                textChars: try attrs.decode(Int.self, forKey: .textChars),
                sampleRate: try attrs.decode(Int.self, forKey: .sampleRate),
                audioBytes: try attrs.decode(Int.self, forKey: .audioBytes),
                attempts: try attrs.decode([DebugSTTAttempt].self, forKey: .attempts)
            ))
        case .vision:
            self = .vision(DebugVisionLog(
                base: base,
                model: try attrs.decode(String.self, forKey: .model),
                mode: try attrs.decode(String.self, forKey: .mode),
                contextPresent: try attrs.decode(Bool.self, forKey: .contextPresent),
                imageBytes: try attrs.decode(Int.self, forKey: .imageBytes),
                imageWidth: try attrs.decode(Int.self, forKey: .imageWidth),
                imageHeight: try attrs.decode(Int.self, forKey: .imageHeight),
                error: try attrs.decodeIfPresent(String.self, forKey: .error)
            ))
        case .postprocess:
            self = .postprocess(DebugPostProcessLog(
                base: base,
                model: try attrs.decode(String.self, forKey: .model),
                contextPresent: try attrs.decode(Bool.self, forKey: .contextPresent),
                sttChars: try attrs.decode(Int.self, forKey: .sttChars),
                outputChars: try attrs.decode(Int.self, forKey: .outputChars),
                kind: try attrs.decode(DebugPostProcessKind.self, forKey: .kind)
            ))
        case .directInput:
            self = .directInput(DebugDirectInputLog(
                base: base,
                success: try attrs.decode(Bool.self, forKey: .success),
                outputChars: try attrs.decode(Int.self, forKey: .outputChars)
            ))
        case .pipeline:
            self = .pipeline(DebugPipelineLog(
                base: base,
                sttChars: try attrs.decode(Int.self, forKey: .sttChars),
                outputChars: try attrs.decode(Int.self, forKey: .outputChars),
                error: try attrs.decodeIfPresent(String.self, forKey: .error)
            ))
        case .contextSummary:
            self = .contextSummary(DebugContextSummaryLog(
                base: base,
                source: try attrs.decode(String.self, forKey: .source),
                appName: try attrs.decodeIfPresent(String.self, forKey: .appName),
                sourceChars: try attrs.decode(Int.self, forKey: .sourceChars),
                summaryChars: try attrs.decode(Int.self, forKey: .summaryChars),
                termsCount: try attrs.decode(Int.self, forKey: .termsCount),
                error: try attrs.decodeIfPresent(String.self, forKey: .error)
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let base = self.base
        try container.encode(base.runID, forKey: .runID)
        try container.encodeIfPresent(base.captureID, forKey: .captureID)
        try container.encode(base.logType, forKey: .stage)
        try container.encode(base.status, forKey: .status)
        try container.encode(base.eventStartMs, forKey: .startedAtMs)
        try container.encode(base.eventEndMs, forKey: .endedAtMs)
        try container.encode(base.recordedAtMs, forKey: .recordedAtMs)

        var attrs = container.nestedContainer(keyedBy: AttrKeys.self, forKey: .attrs)
        switch self {
        case let .recording(log):
            try attrs.encode(log.mode, forKey: .mode)
            try attrs.encode(log.model, forKey: .model)
            try attrs.encode(log.sttProvider, forKey: .sttProvider)
            try attrs.encode(log.sttStreaming, forKey: .sttStreaming)
            try attrs.encode(log.visionEnabled, forKey: .visionEnabled)
            try attrs.encode(log.accessibilitySummaryStarted, forKey: .accessibilitySummaryStarted)
            try attrs.encode(log.sampleRate, forKey: .sampleRate)
            try attrs.encode(log.pcmBytes, forKey: .pcmBytes)
        case let .stt(log):
            try attrs.encode(log.provider, forKey: .provider)
            try attrs.encode(log.transport, forKey: .transport)
            try attrs.encode(log.route, forKey: .route)
            try attrs.encode(log.source, forKey: .source)
            try attrs.encode(log.textChars, forKey: .textChars)
            try attrs.encode(log.sampleRate, forKey: .sampleRate)
            try attrs.encode(log.audioBytes, forKey: .audioBytes)
            try attrs.encode(log.attempts, forKey: .attempts)
        case let .vision(log):
            try attrs.encode(log.model, forKey: .model)
            try attrs.encode(log.mode, forKey: .mode)
            try attrs.encode(log.contextPresent, forKey: .contextPresent)
            try attrs.encode(log.imageBytes, forKey: .imageBytes)
            try attrs.encode(log.imageWidth, forKey: .imageWidth)
            try attrs.encode(log.imageHeight, forKey: .imageHeight)
            try attrs.encodeIfPresent(log.error, forKey: .error)
        case let .postprocess(log):
            try attrs.encode(log.model, forKey: .model)
            try attrs.encode(log.contextPresent, forKey: .contextPresent)
            try attrs.encode(log.sttChars, forKey: .sttChars)
            try attrs.encode(log.outputChars, forKey: .outputChars)
            try attrs.encode(log.kind, forKey: .kind)
        case let .directInput(log):
            try attrs.encode(log.success, forKey: .success)
            try attrs.encode(log.outputChars, forKey: .outputChars)
        case let .pipeline(log):
            try attrs.encode(log.sttChars, forKey: .sttChars)
            try attrs.encode(log.outputChars, forKey: .outputChars)
            try attrs.encodeIfPresent(log.error, forKey: .error)
        case let .contextSummary(log):
            try attrs.encode(log.source, forKey: .source)
            try attrs.encodeIfPresent(log.appName, forKey: .appName)
            try attrs.encode(log.sourceChars, forKey: .sourceChars)
            try attrs.encode(log.summaryChars, forKey: .summaryChars)
            try attrs.encode(log.termsCount, forKey: .termsCount)
            try attrs.encodeIfPresent(log.error, forKey: .error)
        }
    }

    private static func fallbackTransport(for route: DebugSTTRoute) -> STTTransport {
        switch route {
        case .streaming, .streamingFallbackREST:
            return .websocket
        case .rest:
            return .rest
        case .onDevice:
            return .onDevice
        }
    }
}
