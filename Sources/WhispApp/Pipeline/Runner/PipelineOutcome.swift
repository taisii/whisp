import Foundation

enum PipelineSkipReason: String, Sendable {
    case emptyAudio = "empty_audio"
    case emptySTT = "empty_stt"
    case emptyOutput = "empty_output"
}

enum PipelineOutcome: Sendable {
    case completed(sttText: String, outputText: String, directInputSucceeded: Bool)
    case skipped(reason: PipelineSkipReason, sttText: String?, outputText: String?)
    case failed(message: String, sttText: String?, outputText: String?)
}
