import Foundation

enum PipelineState: String {
    case idle
    case recording
    case sttStreaming
    case postProcessing
    case directInput
    case done
    case error

    var label: String {
        switch self {
        case .idle:
            return "待機中"
        case .recording:
            return "録音中"
        case .sttStreaming:
            return "文字起こし中"
        case .postProcessing:
            return "後処理中"
        case .directInput:
            return "直接入力中"
        case .done:
            return "完了"
        case .error:
            return "エラー"
        }
    }

    var symbol: String {
        switch self {
        case .idle:
            return "○"
        case .recording:
            return "●"
        case .sttStreaming, .postProcessing, .directInput:
            return "…"
        case .done:
            return "✓"
        case .error:
            return "!"
        }
    }
}
