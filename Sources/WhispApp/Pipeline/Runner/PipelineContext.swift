import Foundation
import WhispCore

struct PipelineAccessibilitySummaryTask {
    let sourceText: String
    let startedAtDate: Date
    let task: Task<ContextInfo?, Never>
}

struct PipelineRun {
    let id: String
    let startedAtDate: Date
    let appNameAtStart: String?
    let appPIDAtStart: Int32?
    let accessibilitySummarySourceAtStart: String?
    let accessibilitySummaryTask: PipelineAccessibilitySummaryTask?
    let recordingMode: String
    let model: String
    let sttProvider: String
    let sttStreaming: Bool
    let visionEnabled: Bool
    let accessibilitySummaryStarted: Bool
}

struct PipelineRunInput {
    let result: RecordingResult
    let config: Config
    let run: PipelineRun
    let artifacts: DebugRunArtifacts
    let sttStreamingSession: (any STTStreamingSession)?
    let accessibilitySummarySourceAtStop: String?
}

struct RunContext {
    let input: PipelineRunInput
    let transition: (PipelineStateMachine.Event) -> Void
    let notifyWarning: (String) -> Void
}
