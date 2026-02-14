import Foundation

public enum BenchmarkExecutionFlow: String, Codable, CaseIterable, Sendable {
    case stt
    case generationSingle = "generation-single"
    case generationBattle = "generation-battle"

    var internalFlow: BenchmarkCompareFlow {
        switch self {
        case .stt:
            return .stt
        case .generationSingle:
            return .generationSingle
        case .generationBattle:
            return .generationBattle
        }
    }
}

public struct BenchmarkExecutionRequest: Sendable {
    public let flow: BenchmarkExecutionFlow
    public let datasetPath: String
    public let candidateIDs: [String]
    public let judgeModel: String?
    public let force: Bool
    public let benchmarkWorkers: Int?

    public init(
        flow: BenchmarkExecutionFlow,
        datasetPath: String,
        candidateIDs: [String],
        judgeModel: String? = nil,
        force: Bool,
        benchmarkWorkers: Int? = nil
    ) {
        self.flow = flow
        self.datasetPath = datasetPath
        self.candidateIDs = candidateIDs
        self.judgeModel = judgeModel
        self.force = force
        self.benchmarkWorkers = benchmarkWorkers
    }
}

public final class BenchmarkExecutionService: @unchecked Sendable {
    public init() {}

    public func runCompare(request: BenchmarkExecutionRequest) async throws {
        let judgeModel = request.judgeModel.flatMap { LLMModelCatalog.resolveRegistered(rawValue: $0) }
        let options = BenchmarkCompareOptions(
            task: request.flow.internalFlow,
            casesPath: request.datasetPath,
            candidateIDs: request.candidateIDs,
            force: request.force,
            benchmarkWorkers: request.benchmarkWorkers,
            judgeModel: judgeModel
        )
        try await BenchmarkExecutor.runBenchmarkCompare(options: options)
    }
}
