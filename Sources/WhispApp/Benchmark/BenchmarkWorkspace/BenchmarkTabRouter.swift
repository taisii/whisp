import Foundation
import WhispCore

enum BenchmarkWorkspaceTab: String, CaseIterable, Identifiable {
    case stt = "STT"
    case generation = "Generation"
    case candidateManagement = "候補管理"
    case integrity = "Case Integrity"

    var id: String { rawValue }

    var defaultFlow: BenchmarkFlow? {
        switch self {
        case .stt:
            return .stt
        case .generation:
            return .generation
        case .candidateManagement:
            return nil
        case .integrity:
            return nil
        }
    }

    var benchmarkKind: BenchmarkKind {
        switch self {
        case .stt:
            return .stt
        case .generation, .candidateManagement:
            return .generation
        case .integrity:
            return .stt
        }
    }
}
