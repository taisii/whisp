import Foundation
import WhispCore

enum BenchmarkFlow: String, Codable, CaseIterable, Sendable {
    case stt
    case generation

    var benchmarkKind: BenchmarkKind {
        switch self {
        case .stt:
            return .stt
        case .generation:
            return .generation
        }
    }

    var title: String {
        switch self {
        case .stt:
            return "STT"
        case .generation:
            return "Generation"
        }
    }
}

struct BenchmarkWorkspaceState: Equatable {
    var selectedFlow: BenchmarkFlow
    var datasetPath: String
    var forceRun: Bool
    var benchmarkWorkers: Int?
    var compareWorkers: Int?

    init(
        selectedFlow: BenchmarkFlow = .stt,
        datasetPath: String = "",
        forceRun: Bool = false,
        benchmarkWorkers: Int? = nil,
        compareWorkers: Int? = nil
    ) {
        self.selectedFlow = selectedFlow
        self.datasetPath = datasetPath
        self.forceRun = forceRun
        self.benchmarkWorkers = benchmarkWorkers
        self.compareWorkers = compareWorkers
    }
}

struct BenchmarkExecutionPayload: Codable {
    let flow: BenchmarkFlow
    let datasetPath: String
    let candidateIDs: [String]
    let judgeModel: String?
    let forceRun: Bool
    let benchmarkWorkers: Int?
    let compareWorkers: Int?
}
