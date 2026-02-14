import Foundation
import WhispCore

typealias PipelineEventLogger = @Sendable (_ event: String, _ fields: [String: String]) -> Void

struct STTMainSpanTrace {
    let eventStartMs: Int64
    let eventEndMs: Int64
    let status: DebugLogStatus
    let source: String
    let textChars: Int
    let sampleRate: Int
    let audioBytes: Int
    let error: String?
}

struct STTTrace {
    let provider: String
    let transport: STTTransport
    let route: DebugSTTRoute
    let mainSpan: STTMainSpanTrace
    let attempts: [DebugSTTAttempt]
}

struct STTTranscriptionResult {
    let transcript: String
    let usage: STTUsage?
    let trace: STTTrace
    let segments: [STTCommittedSegment]
    let vadIntervals: [VADInterval]

    init(
        transcript: String,
        usage: STTUsage?,
        trace: STTTrace,
        segments: [STTCommittedSegment] = [],
        vadIntervals: [VADInterval] = []
    ) {
        self.transcript = transcript
        self.usage = usage
        self.trace = trace
        self.segments = segments
        self.vadIntervals = vadIntervals
    }
}

struct VisionContextCollectionResult {
    let context: ContextInfo?
    let captureMs: Double
    let analyzeMs: Double
    let totalMs: Double
    let imageData: Data?
    let imageMimeType: String?
    let imageBytes: Int
    let imageWidth: Int
    let imageHeight: Int
    let mode: String
    let error: String?
}
