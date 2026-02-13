import Foundation
import WhispCore

enum BenchmarkWorkspaceTab: String, CaseIterable, Identifiable {
    case stt = "STT"
    case generationSingle = "Generation"
    case generationBattle = "Generation対戦"
    case candidateManagement = "候補管理"
    case integrity = "Case Integrity"

    var id: String { rawValue }

    var defaultFlow: BenchmarkFlow? {
        switch self {
        case .stt:
            return .stt
        case .generationSingle:
            return .generationSingle
        case .generationBattle:
            return .generationBattle
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
        case .generationSingle, .generationBattle, .candidateManagement:
            return .generation
        case .integrity:
            return .stt
        }
    }
}
