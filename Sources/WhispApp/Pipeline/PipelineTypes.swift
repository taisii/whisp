import Foundation
import WhispCore

typealias PipelineEventLogger = @Sendable (_ event: String, _ fields: [String: String]) -> Void

struct STTTranscriptionResult {
    let transcript: String
    let usage: STTUsage?
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
