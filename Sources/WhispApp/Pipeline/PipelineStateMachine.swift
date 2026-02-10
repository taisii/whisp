import Foundation

struct PipelineStateMachine {
    enum Event {
        case startRecording
        case stopRecording
        case startPostProcessing
        case startDirectInput
        case finish
        case fail
        case reset
    }

    private(set) var current: PipelineState = .idle

    @discardableResult
    mutating func apply(_ event: Event) -> PipelineState {
        switch event {
        case .startRecording:
            guard current == .idle else { return current }
            current = .recording
        case .stopRecording:
            guard current == .recording else { return current }
            current = .sttStreaming
        case .startPostProcessing:
            guard current == .sttStreaming else { return current }
            current = .postProcessing
        case .startDirectInput:
            guard current == .postProcessing else { return current }
            current = .directInput
        case .finish:
            guard current == .directInput else { return current }
            current = .done
        case .fail:
            current = .error
        case .reset:
            current = .idle
        }
        return current
    }
}
