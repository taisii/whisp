import Foundation

public enum BenchmarkKind: String, Codable, CaseIterable, Sendable {
    case stt
    case generation
    case vision
}

public struct BenchmarkCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let task: BenchmarkKind
    public let model: String
    public let promptName: String?
    public let generationPromptTemplate: String?
    public let generationPromptHash: String?
    public let options: [String: String]
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        task: BenchmarkKind,
        model: String,
        promptName: String? = nil,
        generationPromptTemplate: String? = nil,
        generationPromptHash: String? = nil,
        options: [String: String] = [:],
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.task = task
        self.model = model
        self.promptName = promptName
        self.generationPromptTemplate = generationPromptTemplate
        self.generationPromptHash = generationPromptHash
        self.options = options
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BenchmarkKey: Codable, Equatable, Hashable, Sendable {
    public let task: BenchmarkKind
    public let datasetPath: String
    public let datasetHash: String
    public let candidateID: String
    public let runtimeOptionsHash: String
    public let evaluatorVersion: String
    public let codeVersion: String

    public init(
        task: BenchmarkKind,
        datasetPath: String,
        datasetHash: String,
        candidateID: String,
        runtimeOptionsHash: String,
        evaluatorVersion: String,
        codeVersion: String
    ) {
        self.task = task
        self.datasetPath = datasetPath
        self.datasetHash = datasetHash
        self.candidateID = candidateID
        self.runtimeOptionsHash = runtimeOptionsHash
        self.evaluatorVersion = evaluatorVersion
        self.codeVersion = codeVersion
    }
}

public struct BenchmarkIntegrityIssue: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let caseID: String
    public let task: BenchmarkKind
    public let issueType: String
    public let missingFields: [String]
    public let sourcePath: String
    public var excluded: Bool
    public let detectedAt: String

    public init(
        id: String,
        caseID: String,
        task: BenchmarkKind,
        issueType: String,
        missingFields: [String],
        sourcePath: String,
        excluded: Bool,
        detectedAt: String
    ) {
        self.id = id
        self.caseID = caseID
        self.task = task
        self.issueType = issueType
        self.missingFields = missingFields
        self.sourcePath = sourcePath
        self.excluded = excluded
        self.detectedAt = detectedAt
    }
}

public enum BenchmarkRunStatus: String, Codable, Sendable {
    case running
    case completed
    case failed
}

public enum BenchmarkCaseStatus: String, Codable, Sendable {
    case ok
    case skipped
    case error
}

public enum BenchmarkEventStage: String, Codable, CaseIterable, Sendable {
    case loadCase = "load_case"
    case audioReplay = "audio_replay"
    case stt
    case context
    case generation
    case judge
    case aggregate
    case cache
    case error
    case artifactWriteFailed = "artifact_write_failed"
}

public enum BenchmarkEventStatus: String, Codable, Sendable {
    case ok
    case error
    case skipped
    case cancelled
}

public struct BenchmarkArtifactRef: Codable, Equatable, Sendable {
    public var relativePath: String
    public var mimeType: String
    public var sha256: String
    public var bytes: Int
    public var maskRuleID: String?

    public init(
        relativePath: String,
        mimeType: String,
        sha256: String,
        bytes: Int,
        maskRuleID: String? = nil
    ) {
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.sha256 = sha256
        self.bytes = bytes
        self.maskRuleID = maskRuleID
    }
}

public struct BenchmarkReferenceSources: Codable, Equatable, Sendable {
    public var transcript: String?
    public var input: String?
    public var reference: String?
    public var intent: String?

    public init(
        transcript: String? = nil,
        input: String? = nil,
        reference: String? = nil,
        intent: String? = nil
    ) {
        self.transcript = transcript
        self.input = input
        self.reference = reference
        self.intent = intent
    }
}

public struct BenchmarkCacheRecord: Codable, Equatable, Sendable {
    public var hit: Bool
    public var key: String?
    public var namespace: String?
    public var keyMaterialRef: BenchmarkArtifactRef?

    public init(
        hit: Bool,
        key: String? = nil,
        namespace: String? = nil,
        keyMaterialRef: BenchmarkArtifactRef? = nil
    ) {
        self.hit = hit
        self.key = key
        self.namespace = namespace
        self.keyMaterialRef = keyMaterialRef
    }
}

public enum BenchmarkCompareMode: String, Codable, Sendable {
    case standard
    case pairwise
}

public enum PairwiseWinner: String, Codable, Sendable {
    case a
    case b
    case tie
}

public struct PairwiseCaseJudgement: Codable, Equatable, Sendable {
    public var overallWinner: PairwiseWinner
    public var intentWinner: PairwiseWinner
    public var hallucinationWinner: PairwiseWinner
    public var styleContextWinner: PairwiseWinner
    public var overallReason: String?
    public var intentReason: String?
    public var hallucinationReason: String?
    public var styleContextReason: String?
    public var confidence: String?

    public init(
        overallWinner: PairwiseWinner,
        intentWinner: PairwiseWinner,
        hallucinationWinner: PairwiseWinner,
        styleContextWinner: PairwiseWinner,
        overallReason: String? = nil,
        intentReason: String? = nil,
        hallucinationReason: String? = nil,
        styleContextReason: String? = nil,
        confidence: String? = nil
    ) {
        self.overallWinner = overallWinner
        self.intentWinner = intentWinner
        self.hallucinationWinner = hallucinationWinner
        self.styleContextWinner = styleContextWinner
        self.overallReason = overallReason
        self.intentReason = intentReason
        self.hallucinationReason = hallucinationReason
        self.styleContextReason = styleContextReason
        self.confidence = confidence
    }
}

public struct PairwiseRunSummary: Codable, Equatable, Sendable {
    public var judgedCases: Int
    public var judgeErrorCases: Int
    public var overallAWins: Int
    public var overallBWins: Int
    public var overallTies: Int
    public var intentAWins: Int
    public var intentBWins: Int
    public var intentTies: Int
    public var hallucinationAWins: Int
    public var hallucinationBWins: Int
    public var hallucinationTies: Int
    public var styleContextAWins: Int
    public var styleContextBWins: Int
    public var styleContextTies: Int

    public init(
        judgedCases: Int = 0,
        judgeErrorCases: Int = 0,
        overallAWins: Int = 0,
        overallBWins: Int = 0,
        overallTies: Int = 0,
        intentAWins: Int = 0,
        intentBWins: Int = 0,
        intentTies: Int = 0,
        hallucinationAWins: Int = 0,
        hallucinationBWins: Int = 0,
        hallucinationTies: Int = 0,
        styleContextAWins: Int = 0,
        styleContextBWins: Int = 0,
        styleContextTies: Int = 0
    ) {
        self.judgedCases = judgedCases
        self.judgeErrorCases = judgeErrorCases
        self.overallAWins = overallAWins
        self.overallBWins = overallBWins
        self.overallTies = overallTies
        self.intentAWins = intentAWins
        self.intentBWins = intentBWins
        self.intentTies = intentTies
        self.hallucinationAWins = hallucinationAWins
        self.hallucinationBWins = hallucinationBWins
        self.hallucinationTies = hallucinationTies
        self.styleContextAWins = styleContextAWins
        self.styleContextBWins = styleContextBWins
        self.styleContextTies = styleContextTies
    }
}

public struct BenchmarkCaseMetrics: Codable, Equatable, Sendable {
    public var exactMatch: Bool?
    public var cer: Double?
    public var termPrecision: Double?
    public var termRecall: Double?
    public var termF1: Double?
    public var intentMatch: Bool?
    public var intentScore: Int?
    public var intentPreservationScore: Double?
    public var hallucinationScore: Double?
    public var hallucinationRate: Double?
    public var sttTotalMs: Double?
    public var sttAfterStopMs: Double?
    public var postMs: Double?
    public var totalAfterStopMs: Double?
    public var latencyMs: Double?
    public var audioSeconds: Double?
    public var outputChars: Int?
    public var pairwise: PairwiseCaseJudgement?

    public init(
        exactMatch: Bool? = nil,
        cer: Double? = nil,
        termPrecision: Double? = nil,
        termRecall: Double? = nil,
        termF1: Double? = nil,
        intentMatch: Bool? = nil,
        intentScore: Int? = nil,
        intentPreservationScore: Double? = nil,
        hallucinationScore: Double? = nil,
        hallucinationRate: Double? = nil,
        sttTotalMs: Double? = nil,
        sttAfterStopMs: Double? = nil,
        postMs: Double? = nil,
        totalAfterStopMs: Double? = nil,
        latencyMs: Double? = nil,
        audioSeconds: Double? = nil,
        outputChars: Int? = nil,
        pairwise: PairwiseCaseJudgement? = nil
    ) {
        self.exactMatch = exactMatch
        self.cer = cer
        self.termPrecision = termPrecision
        self.termRecall = termRecall
        self.termF1 = termF1
        self.intentMatch = intentMatch
        self.intentScore = intentScore
        self.intentPreservationScore = intentPreservationScore
        self.hallucinationScore = hallucinationScore
        self.hallucinationRate = hallucinationRate
        self.sttTotalMs = sttTotalMs
        self.sttAfterStopMs = sttAfterStopMs
        self.postMs = postMs
        self.totalAfterStopMs = totalAfterStopMs
        self.latencyMs = latencyMs
        self.audioSeconds = audioSeconds
        self.outputChars = outputChars
        self.pairwise = pairwise
    }
}

public struct BenchmarkCaseResult: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var status: BenchmarkCaseStatus
    public var reason: String?
    public var cache: BenchmarkCacheRecord?
    public var sources: BenchmarkReferenceSources
    public var contextUsed: Bool?
    public var visionImageAttached: Bool?
    public var metrics: BenchmarkCaseMetrics

    public init(
        id: String,
        status: BenchmarkCaseStatus,
        reason: String? = nil,
        cache: BenchmarkCacheRecord? = nil,
        sources: BenchmarkReferenceSources = BenchmarkReferenceSources(),
        contextUsed: Bool? = nil,
        visionImageAttached: Bool? = nil,
        metrics: BenchmarkCaseMetrics = BenchmarkCaseMetrics()
    ) {
        self.id = id
        self.status = status
        self.reason = reason
        self.cache = cache
        self.sources = sources
        self.contextUsed = contextUsed
        self.visionImageAttached = visionImageAttached
        self.metrics = metrics
    }
}

public struct BenchmarkLatencyDistribution: Codable, Equatable, Sendable {
    public var avg: Double?
    public var p50: Double?
    public var p95: Double?
    public var p99: Double?

    public init(
        avg: Double? = nil,
        p50: Double? = nil,
        p95: Double? = nil,
        p99: Double? = nil
    ) {
        self.avg = avg
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
    }
}

public struct BenchmarkCostBreakdown: Codable, Equatable, Sendable {
    public var sttUSD: Double?
    public var llmUSD: Double?
    public var totalUSD: Double?

    public init(
        sttUSD: Double? = nil,
        llmUSD: Double? = nil,
        totalUSD: Double? = nil
    ) {
        self.sttUSD = sttUSD
        self.llmUSD = llmUSD
        self.totalUSD = totalUSD
    }
}

public struct BenchmarkRunCommonOptions: Codable, Equatable, Sendable {
    public var sourceCasesPath: String
    public var datasetHash: String?
    public var runtimeOptionsHash: String?
    public var evaluatorVersion: String?
    public var codeVersion: String?
    public var caseLimit: Int?
    public var useCache: Bool?

    public init(
        sourceCasesPath: String,
        datasetHash: String? = nil,
        runtimeOptionsHash: String? = nil,
        evaluatorVersion: String? = nil,
        codeVersion: String? = nil,
        caseLimit: Int? = nil,
        useCache: Bool? = nil
    ) {
        self.sourceCasesPath = sourceCasesPath
        self.datasetHash = datasetHash
        self.runtimeOptionsHash = runtimeOptionsHash
        self.evaluatorVersion = evaluatorVersion
        self.codeVersion = codeVersion
        self.caseLimit = caseLimit
        self.useCache = useCache
    }
}

public struct BenchmarkSTTRunOptions: Codable, Equatable, Sendable {
    public var common: BenchmarkRunCommonOptions
    public var candidateID: String?
    public var sttExecutionProfile: String?
    public var sttMode: String?
    public var chunkMs: Int?
    public var realtime: Bool?
    public var minAudioSeconds: Double?

    public init(
        common: BenchmarkRunCommonOptions,
        candidateID: String? = nil,
        sttExecutionProfile: String? = nil,
        sttMode: String? = nil,
        chunkMs: Int? = nil,
        realtime: Bool? = nil,
        minAudioSeconds: Double? = nil
    ) {
        self.common = common
        self.candidateID = candidateID
        self.sttExecutionProfile = sttExecutionProfile
        self.sttMode = sttMode
        self.chunkMs = chunkMs
        self.realtime = realtime
        self.minAudioSeconds = minAudioSeconds
    }
}

public struct BenchmarkGenerationRunOptions: Codable, Equatable, Sendable {
    public var common: BenchmarkRunCommonOptions
    public var candidateID: String?
    public var promptName: String?
    public var generationPromptHash: String?
    public var requireContext: Bool?
    public var llmEvalEnabled: Bool?
    public var llmEvalModel: String?
    public var llmModel: String?

    public init(
        common: BenchmarkRunCommonOptions,
        candidateID: String? = nil,
        promptName: String? = nil,
        generationPromptHash: String? = nil,
        requireContext: Bool? = nil,
        llmEvalEnabled: Bool? = nil,
        llmEvalModel: String? = nil,
        llmModel: String? = nil
    ) {
        self.common = common
        self.candidateID = candidateID
        self.promptName = promptName
        self.generationPromptHash = generationPromptHash
        self.requireContext = requireContext
        self.llmEvalEnabled = llmEvalEnabled
        self.llmEvalModel = llmEvalModel
        self.llmModel = llmModel
    }
}

public struct BenchmarkGenerationPairwiseRunOptions: Codable, Equatable, Sendable {
    public var common: BenchmarkRunCommonOptions
    public var pairCandidateAID: String
    public var pairCandidateBID: String
    public var pairJudgeModel: String
    public var llmModel: String?

    public init(
        common: BenchmarkRunCommonOptions,
        pairCandidateAID: String,
        pairCandidateBID: String,
        pairJudgeModel: String,
        llmModel: String? = nil
    ) {
        self.common = common
        self.pairCandidateAID = pairCandidateAID
        self.pairCandidateBID = pairCandidateBID
        self.pairJudgeModel = pairJudgeModel
        self.llmModel = llmModel
    }
}

public struct BenchmarkVisionRunOptions: Codable, Equatable, Sendable {
    public var common: BenchmarkRunCommonOptions

    public init(common: BenchmarkRunCommonOptions) {
        self.common = common
    }
}

public enum BenchmarkRunOptions: Codable, Equatable, Sendable {
    case stt(BenchmarkSTTRunOptions)
    case generation(BenchmarkGenerationRunOptions)
    case generationPairwise(BenchmarkGenerationPairwiseRunOptions)
    case vision(BenchmarkVisionRunOptions)

    private enum CodingKeys: String, CodingKey {
        case kind
        case stt
        case generation
        case generationPairwise
        case vision
    }

    private enum Kind: String, Codable {
        case stt
        case generation
        case generationPairwise = "generation_pairwise"
        case vision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .stt:
            self = .stt(try container.decode(BenchmarkSTTRunOptions.self, forKey: .stt))
        case .generation:
            self = .generation(try container.decode(BenchmarkGenerationRunOptions.self, forKey: .generation))
        case .generationPairwise:
            self = .generationPairwise(try container.decode(BenchmarkGenerationPairwiseRunOptions.self, forKey: .generationPairwise))
        case .vision:
            self = .vision(try container.decode(BenchmarkVisionRunOptions.self, forKey: .vision))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .stt(value):
            try container.encode(Kind.stt, forKey: .kind)
            try container.encode(value, forKey: .stt)
        case let .generation(value):
            try container.encode(Kind.generation, forKey: .kind)
            try container.encode(value, forKey: .generation)
        case let .generationPairwise(value):
            try container.encode(Kind.generationPairwise, forKey: .kind)
            try container.encode(value, forKey: .generationPairwise)
        case let .vision(value):
            try container.encode(Kind.vision, forKey: .kind)
            try container.encode(value, forKey: .vision)
        }
    }

    public var common: BenchmarkRunCommonOptions {
        switch self {
        case let .stt(value):
            return value.common
        case let .generation(value):
            return value.common
        case let .generationPairwise(value):
            return value.common
        case let .vision(value):
            return value.common
        }
    }

    public var sourceCasesPath: String { common.sourceCasesPath }
    public var datasetHash: String? { common.datasetHash }
    public var runtimeOptionsHash: String? { common.runtimeOptionsHash }
    public var evaluatorVersion: String? { common.evaluatorVersion }
    public var codeVersion: String? { common.codeVersion }
    public var caseLimit: Int? { common.caseLimit }
    public var useCache: Bool? { common.useCache }

    public var sttExecutionProfile: String? {
        if case let .stt(value) = self {
            return value.sttExecutionProfile
        }
        return nil
    }

    public var candidateID: String? {
        switch self {
        case let .stt(value):
            return value.candidateID
        case let .generation(value):
            return value.candidateID
        case .generationPairwise, .vision:
            return nil
        }
    }

    public var promptName: String? {
        if case let .generation(value) = self {
            return value.promptName
        }
        return nil
    }

    public var generationPromptHash: String? {
        if case let .generation(value) = self {
            return value.generationPromptHash
        }
        return nil
    }

    public var sttMode: String? {
        if case let .stt(value) = self {
            return value.sttMode
        }
        return nil
    }

    public var chunkMs: Int? {
        if case let .stt(value) = self {
            return value.chunkMs
        }
        return nil
    }

    public var realtime: Bool? {
        if case let .stt(value) = self {
            return value.realtime
        }
        return nil
    }

    public var requireContext: Bool? {
        if case let .generation(value) = self {
            return value.requireContext
        }
        return nil
    }

    public var minAudioSeconds: Double? {
        if case let .stt(value) = self {
            return value.minAudioSeconds
        }
        return nil
    }

    public var llmEvalEnabled: Bool? {
        if case let .generation(value) = self {
            return value.llmEvalEnabled
        }
        return nil
    }

    public var llmEvalModel: String? {
        if case let .generation(value) = self {
            return value.llmEvalModel
        }
        return nil
    }

    public var llmModel: String? {
        switch self {
        case let .generation(value):
            return value.llmModel
        case let .generationPairwise(value):
            return value.llmModel
        case .stt, .vision:
            return nil
        }
    }

    public var compareMode: BenchmarkCompareMode? {
        switch self {
        case .generationPairwise:
            return .pairwise
        case .stt, .generation, .vision:
            return nil
        }
    }

    public var pairCandidateAID: String? {
        if case let .generationPairwise(value) = self {
            return value.pairCandidateAID
        }
        return nil
    }

    public var pairCandidateBID: String? {
        if case let .generationPairwise(value) = self {
            return value.pairCandidateBID
        }
        return nil
    }

    public var pairJudgeModel: String? {
        if case let .generationPairwise(value) = self {
            return value.pairJudgeModel
        }
        return nil
    }
}

public struct BenchmarkRunCounts: Codable, Equatable, Sendable {
    public var casesTotal: Int
    public var casesSelected: Int
    public var executedCases: Int
    public var skippedCases: Int
    public var failedCases: Int
    public var cachedHits: Int

    public init(
        casesTotal: Int,
        casesSelected: Int,
        executedCases: Int,
        skippedCases: Int,
        failedCases: Int,
        cachedHits: Int = 0
    ) {
        self.casesTotal = casesTotal
        self.casesSelected = casesSelected
        self.executedCases = executedCases
        self.skippedCases = skippedCases
        self.failedCases = failedCases
        self.cachedHits = cachedHits
    }
}

public struct BenchmarkSTTRunMetrics: Codable, Equatable, Sendable {
    public var counts: BenchmarkRunCounts
    public var exactMatchRate: Double?
    public var avgCER: Double?
    public var weightedCER: Double?
    public var latencyMs: BenchmarkLatencyDistribution?
    public var afterStopLatencyMs: BenchmarkLatencyDistribution?

    public init(
        counts: BenchmarkRunCounts,
        exactMatchRate: Double? = nil,
        avgCER: Double? = nil,
        weightedCER: Double? = nil,
        latencyMs: BenchmarkLatencyDistribution? = nil,
        afterStopLatencyMs: BenchmarkLatencyDistribution? = nil
    ) {
        self.counts = counts
        self.exactMatchRate = exactMatchRate
        self.avgCER = avgCER
        self.weightedCER = weightedCER
        self.latencyMs = latencyMs
        self.afterStopLatencyMs = afterStopLatencyMs
    }
}

public struct BenchmarkGenerationRunMetrics: Codable, Equatable, Sendable {
    public var counts: BenchmarkRunCounts
    public var exactMatchRate: Double?
    public var avgCER: Double?
    public var weightedCER: Double?
    public var intentPreservationScore: Double?
    public var hallucinationScore: Double?
    public var hallucinationRate: Double?
    public var postLatencyMs: BenchmarkLatencyDistribution?

    public init(
        counts: BenchmarkRunCounts,
        exactMatchRate: Double? = nil,
        avgCER: Double? = nil,
        weightedCER: Double? = nil,
        intentPreservationScore: Double? = nil,
        hallucinationScore: Double? = nil,
        hallucinationRate: Double? = nil,
        postLatencyMs: BenchmarkLatencyDistribution? = nil
    ) {
        self.counts = counts
        self.exactMatchRate = exactMatchRate
        self.avgCER = avgCER
        self.weightedCER = weightedCER
        self.intentPreservationScore = intentPreservationScore
        self.hallucinationScore = hallucinationScore
        self.hallucinationRate = hallucinationRate
        self.postLatencyMs = postLatencyMs
    }
}

public struct BenchmarkGenerationPairwiseRunMetrics: Codable, Equatable, Sendable {
    public var counts: BenchmarkRunCounts
    public var pairwiseSummary: PairwiseRunSummary

    public init(counts: BenchmarkRunCounts, pairwiseSummary: PairwiseRunSummary) {
        self.counts = counts
        self.pairwiseSummary = pairwiseSummary
    }
}

public struct BenchmarkVisionRunMetrics: Codable, Equatable, Sendable {
    public var counts: BenchmarkRunCounts
    public var avgCER: Double?
    public var avgTermsF1: Double?
    public var latencyMs: BenchmarkLatencyDistribution?

    public init(
        counts: BenchmarkRunCounts,
        avgCER: Double? = nil,
        avgTermsF1: Double? = nil,
        latencyMs: BenchmarkLatencyDistribution? = nil
    ) {
        self.counts = counts
        self.avgCER = avgCER
        self.avgTermsF1 = avgTermsF1
        self.latencyMs = latencyMs
    }
}

public enum BenchmarkRunMetrics: Codable, Equatable, Sendable {
    case stt(BenchmarkSTTRunMetrics)
    case generation(BenchmarkGenerationRunMetrics)
    case generationPairwise(BenchmarkGenerationPairwiseRunMetrics)
    case vision(BenchmarkVisionRunMetrics)

    private enum CodingKeys: String, CodingKey {
        case kind
        case stt
        case generation
        case generationPairwise
        case vision
    }

    private enum Kind: String, Codable {
        case stt
        case generation
        case generationPairwise = "generation_pairwise"
        case vision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .stt:
            self = .stt(try container.decode(BenchmarkSTTRunMetrics.self, forKey: .stt))
        case .generation:
            self = .generation(try container.decode(BenchmarkGenerationRunMetrics.self, forKey: .generation))
        case .generationPairwise:
            self = .generationPairwise(try container.decode(BenchmarkGenerationPairwiseRunMetrics.self, forKey: .generationPairwise))
        case .vision:
            self = .vision(try container.decode(BenchmarkVisionRunMetrics.self, forKey: .vision))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .stt(value):
            try container.encode(Kind.stt, forKey: .kind)
            try container.encode(value, forKey: .stt)
        case let .generation(value):
            try container.encode(Kind.generation, forKey: .kind)
            try container.encode(value, forKey: .generation)
        case let .generationPairwise(value):
            try container.encode(Kind.generationPairwise, forKey: .kind)
            try container.encode(value, forKey: .generationPairwise)
        case let .vision(value):
            try container.encode(Kind.vision, forKey: .kind)
            try container.encode(value, forKey: .vision)
        }
    }

    public var counts: BenchmarkRunCounts {
        switch self {
        case let .stt(value):
            return value.counts
        case let .generation(value):
            return value.counts
        case let .generationPairwise(value):
            return value.counts
        case let .vision(value):
            return value.counts
        }
    }

    public var casesTotal: Int { counts.casesTotal }
    public var casesSelected: Int { counts.casesSelected }
    public var executedCases: Int { counts.executedCases }
    public var skippedCases: Int { counts.skippedCases }
    public var failedCases: Int { counts.failedCases }
    public var cachedHits: Int { counts.cachedHits }

    public var exactMatchRate: Double? {
        switch self {
        case let .stt(value):
            return value.exactMatchRate
        case let .generation(value):
            return value.exactMatchRate
        case .generationPairwise, .vision:
            return nil
        }
    }

    public var avgCER: Double? {
        switch self {
        case let .stt(value):
            return value.avgCER
        case let .generation(value):
            return value.avgCER
        case let .vision(value):
            return value.avgCER
        case .generationPairwise:
            return nil
        }
    }

    public var weightedCER: Double? {
        switch self {
        case let .stt(value):
            return value.weightedCER
        case let .generation(value):
            return value.weightedCER
        case .generationPairwise, .vision:
            return nil
        }
    }

    public var avgTermsF1: Double? {
        if case let .vision(value) = self {
            return value.avgTermsF1
        }
        return nil
    }

    public var intentPreservationScore: Double? {
        if case let .generation(value) = self {
            return value.intentPreservationScore
        }
        return nil
    }

    public var hallucinationScore: Double? {
        if case let .generation(value) = self {
            return value.hallucinationScore
        }
        return nil
    }

    public var hallucinationRate: Double? {
        if case let .generation(value) = self {
            return value.hallucinationRate
        }
        return nil
    }

    public var latencyMs: BenchmarkLatencyDistribution? {
        switch self {
        case let .stt(value):
            return value.latencyMs
        case let .vision(value):
            return value.latencyMs
        case .generation, .generationPairwise:
            return nil
        }
    }

    public var afterStopLatencyMs: BenchmarkLatencyDistribution? {
        if case let .stt(value) = self {
            return value.afterStopLatencyMs
        }
        return nil
    }

    public var postLatencyMs: BenchmarkLatencyDistribution? {
        if case let .generation(value) = self {
            return value.postLatencyMs
        }
        return nil
    }

    public var pairwiseSummary: PairwiseRunSummary? {
        if case let .generationPairwise(value) = self {
            return value.pairwiseSummary
        }
        return nil
    }
}

public struct BenchmarkRunPaths: Codable, Equatable, Sendable {
    public var manifestPath: String
    public var orchestratorEventsPath: String
    public var casesIndexPath: String
    public var casesDirectoryPath: String

    public init(
        manifestPath: String,
        orchestratorEventsPath: String,
        casesIndexPath: String,
        casesDirectoryPath: String
    ) {
        self.manifestPath = manifestPath
        self.orchestratorEventsPath = orchestratorEventsPath
        self.casesIndexPath = casesIndexPath
        self.casesDirectoryPath = casesDirectoryPath
    }
}

public struct BenchmarkRunRecord: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public var kind: BenchmarkKind
    public var status: BenchmarkRunStatus
    public var createdAt: String
    public var updatedAt: String

    public var options: BenchmarkRunOptions
    public var candidateID: String?
    public var benchmarkKey: BenchmarkKey?
    public var metrics: BenchmarkRunMetrics
    public var paths: BenchmarkRunPaths

    public init(
        schemaVersion: Int = 7,
        id: String,
        kind: BenchmarkKind,
        status: BenchmarkRunStatus = .completed,
        createdAt: String,
        updatedAt: String,
        options: BenchmarkRunOptions,
        candidateID: String? = nil,
        benchmarkKey: BenchmarkKey? = nil,
        metrics: BenchmarkRunMetrics,
        paths: BenchmarkRunPaths
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.options = options
        self.candidateID = candidateID
        self.benchmarkKey = benchmarkKey
        self.metrics = metrics
        self.paths = paths
    }
}

public struct BenchmarkCasePaths: Codable, Equatable, Sendable {
    public var caseDirectoryPath: String
    public var manifestPath: String
    public var metricsPath: String
    public var eventsPath: String
    public var ioDirectoryPath: String
    public var artifactsDirectoryPath: String

    public init(
        caseDirectoryPath: String,
        manifestPath: String,
        metricsPath: String,
        eventsPath: String,
        ioDirectoryPath: String,
        artifactsDirectoryPath: String
    ) {
        self.caseDirectoryPath = caseDirectoryPath
        self.manifestPath = manifestPath
        self.metricsPath = metricsPath
        self.eventsPath = eventsPath
        self.ioDirectoryPath = ioDirectoryPath
        self.artifactsDirectoryPath = artifactsDirectoryPath
    }
}

public struct BenchmarkCaseManifest: Codable, Equatable, Sendable {
    public let runID: String
    public let caseID: String
    public var status: BenchmarkCaseStatus
    public var reason: String?
    public var startedAt: String
    public var endedAt: String?
    public var audioFilePath: String?
    public var contextUsed: Bool
    public var visionImageAttached: Bool
    public var transcriptSource: String?
    public var inputSource: String?
    public var referenceSource: String?

    public init(
        runID: String,
        caseID: String,
        status: BenchmarkCaseStatus,
        reason: String? = nil,
        startedAt: String,
        endedAt: String? = nil,
        audioFilePath: String? = nil,
        contextUsed: Bool,
        visionImageAttached: Bool,
        transcriptSource: String? = nil,
        inputSource: String? = nil,
        referenceSource: String? = nil
    ) {
        self.runID = runID
        self.caseID = caseID
        self.status = status
        self.reason = reason
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioFilePath = audioFilePath
        self.contextUsed = contextUsed
        self.visionImageAttached = visionImageAttached
        self.transcriptSource = transcriptSource
        self.inputSource = inputSource
        self.referenceSource = referenceSource
    }
}

public enum BenchmarkOrchestratorStage: String, Codable, CaseIterable, Sendable {
    case runStart = "run_start"
    case caseQueued = "case_queued"
    case caseStarted = "case_started"
    case caseFinished = "case_finished"
    case caseFailed = "case_failed"
    case runCompleted = "run_completed"
    case runFailed = "run_failed"
    case runCancelled = "run_cancelled"
}

public struct BenchmarkOrchestratorEvent: Codable, Equatable, Sendable {
    public var runID: String
    public var caseID: String?
    public var stage: BenchmarkOrchestratorStage
    public var status: BenchmarkEventStatus
    public var recordedAtMs: Int64
    public var attrs: [String: String]?

    public init(
        runID: String,
        caseID: String? = nil,
        stage: BenchmarkOrchestratorStage,
        status: BenchmarkEventStatus,
        recordedAtMs: Int64,
        attrs: [String: String]? = nil
    ) {
        self.runID = runID
        self.caseID = caseID
        self.stage = stage
        self.status = status
        self.recordedAtMs = recordedAtMs
        self.attrs = attrs
    }
}

public struct BenchmarkCaseEventBase: Equatable, Sendable {
    public let runID: String
    public let caseID: String
    public let stage: BenchmarkEventStage
    public let status: BenchmarkEventStatus
    public let startedAtMs: Int64
    public let endedAtMs: Int64
    public let recordedAtMs: Int64

    public init(
        runID: String,
        caseID: String,
        stage: BenchmarkEventStage,
        status: BenchmarkEventStatus,
        startedAtMs: Int64,
        endedAtMs: Int64,
        recordedAtMs: Int64
    ) {
        self.runID = runID
        self.caseID = caseID
        self.stage = stage
        self.status = status
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.recordedAtMs = recordedAtMs
    }
}

public struct BenchmarkLoadCaseLog: Equatable, Sendable {
    public let base: BenchmarkCaseEventBase
    public let sources: BenchmarkReferenceSources
    public let contextPresent: Bool
    public let visionImagePresent: Bool
    public let audioFilePath: String?
    public let rawRowRef: BenchmarkArtifactRef?

    public init(
        base: BenchmarkCaseEventBase,
        sources: BenchmarkReferenceSources,
        contextPresent: Bool,
        visionImagePresent: Bool,
        audioFilePath: String?,
        rawRowRef: BenchmarkArtifactRef?
    ) {
        self.base = base
        self.sources = sources
        self.contextPresent = contextPresent
        self.visionImagePresent = visionImagePresent
        self.audioFilePath = audioFilePath
        self.rawRowRef = rawRowRef
    }
}

public struct BenchmarkAudioReplayLog: Equatable, Sendable {
    public let base: BenchmarkCaseEventBase
    public let profile: String
    public let chunkMs: Int?
    public let realtime: Bool

    public init(
        base: BenchmarkCaseEventBase,
        profile: String,
        chunkMs: Int?,
        realtime: Bool
    ) {
        self.base = base
        self.profile = profile
        self.chunkMs = chunkMs
        self.realtime = realtime
    }
}

public struct BenchmarkSTTAttempt: Codable, Equatable, Sendable {
    public let kind: String
    public let status: BenchmarkEventStatus
    public let startedAtMs: Int64
    public let endedAtMs: Int64
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case status
        case startedAtMs = "started_at_ms"
        case endedAtMs = "ended_at_ms"
        case error
    }

    public init(
        kind: String,
        status: BenchmarkEventStatus,
        startedAtMs: Int64,
        endedAtMs: Int64,
        error: String? = nil
    ) {
        self.kind = kind
        self.status = status
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.error = error
    }
}

public struct BenchmarkSTTLog: Equatable, Sendable {
    public let base: BenchmarkCaseEventBase
    public let provider: String?
    public let mode: String?
    public let transcriptText: String?
    public let referenceText: String?
    public let transcriptChars: Int?
    public let cer: Double?
    public let sttTotalMs: Double?
    public let sttAfterStopMs: Double?
    public let attempts: [BenchmarkSTTAttempt]?
    public let rawResponseRef: BenchmarkArtifactRef?
    public let error: String?

    public init(
        base: BenchmarkCaseEventBase,
        provider: String?,
        mode: String?,
        transcriptText: String? = nil,
        referenceText: String? = nil,
        transcriptChars: Int?,
        cer: Double?,
        sttTotalMs: Double?,
        sttAfterStopMs: Double?,
        attempts: [BenchmarkSTTAttempt]?,
        rawResponseRef: BenchmarkArtifactRef?,
        error: String?
    ) {
        self.base = base
        self.provider = provider
        self.mode = mode
        self.transcriptText = transcriptText
        self.referenceText = referenceText
        self.transcriptChars = transcriptChars
        self.cer = cer
        self.sttTotalMs = sttTotalMs
        self.sttAfterStopMs = sttAfterStopMs
        self.attempts = attempts
        self.rawResponseRef = rawResponseRef
        self.error = error
    }
}

public struct BenchmarkContextLog: Equatable, Sendable {
    public let base: BenchmarkCaseEventBase
    public let contextPresent: Bool
    public let sourceChars: Int?
    public let summaryChars: Int?
    public let termsCount: Int?
    public let rawContextRef: BenchmarkArtifactRef?
    public let error: String?

    public init(
        base: BenchmarkCaseEventBase,
        contextPresent: Bool,
        sourceChars: Int?,
        summaryChars: Int?,
        termsCount: Int?,
        rawContextRef: BenchmarkArtifactRef?,
        error: String?
    ) {
        self.base = base
        self.contextPresent = contextPresent
        self.sourceChars = sourceChars
        self.summaryChars = summaryChars
        self.termsCount = termsCount
        self.rawContextRef = rawContextRef
        self.error = error
    }
}

public struct BenchmarkGenerationLog: Equatable, Sendable {
    public let base: BenchmarkCaseEventBase
    public let model: String?
    public let inputChars: Int?
    public let outputChars: Int?
    public let postMs: Double?
    public let promptRef: BenchmarkArtifactRef?
    public let responseRef: BenchmarkArtifactRef?
    public let error: String?

    public init(
        base: BenchmarkCaseEventBase,
        model: String?,
        inputChars: Int?,
        outputChars: Int?,
        postMs: Double?,
        promptRef: BenchmarkArtifactRef?,
        responseRef: BenchmarkArtifactRef?,
        error: String?
    ) {
        self.base = base
        self.model = model
        self.inputChars = inputChars
        self.outputChars = outputChars
        self.postMs = postMs
        self.promptRef = promptRef
        self.responseRef = responseRef
        self.error = error
    }
}

public struct BenchmarkJudgeLog: Equatable, Sendable {
    public let base: BenchmarkCaseEventBase
    public let model: String?
    public let match: Bool?
    public let score: Int?
    public let intentPreservationScore: Double?
    public let hallucinationScore: Double?
    public let hallucinationRate: Double?
    public let requestRef: BenchmarkArtifactRef?
    public let responseRef: BenchmarkArtifactRef?
    public let error: String?

    public init(
        base: BenchmarkCaseEventBase,
        model: String?,
        match: Bool?,
        score: Int?,
        intentPreservationScore: Double?,
        hallucinationScore: Double?,
        hallucinationRate: Double?,
        requestRef: BenchmarkArtifactRef?,
        responseRef: BenchmarkArtifactRef?,
        error: String?
    ) {
        self.base = base
        self.model = model
        self.match = match
        self.score = score
        self.intentPreservationScore = intentPreservationScore
        self.hallucinationScore = hallucinationScore
        self.hallucinationRate = hallucinationRate
        self.requestRef = requestRef
        self.responseRef = responseRef
        self.error = error
    }
}

public struct BenchmarkAggregateLog: Equatable, Sendable {
    public let base: BenchmarkCaseEventBase
    public let exactMatch: Bool?
    public let cer: Double?
    public let intentMatch: Bool?
    public let intentScore: Int?
    public let intentPreservationScore: Double?
    public let hallucinationScore: Double?
    public let hallucinationRate: Double?
    public let latencyMs: Double?
    public let totalAfterStopMs: Double?
    public let outputChars: Int?

    public init(
        base: BenchmarkCaseEventBase,
        exactMatch: Bool?,
        cer: Double?,
        intentMatch: Bool?,
        intentScore: Int?,
        intentPreservationScore: Double?,
        hallucinationScore: Double?,
        hallucinationRate: Double?,
        latencyMs: Double?,
        totalAfterStopMs: Double?,
        outputChars: Int?
    ) {
        self.base = base
        self.exactMatch = exactMatch
        self.cer = cer
        self.intentMatch = intentMatch
        self.intentScore = intentScore
        self.intentPreservationScore = intentPreservationScore
        self.hallucinationScore = hallucinationScore
        self.hallucinationRate = hallucinationRate
        self.latencyMs = latencyMs
        self.totalAfterStopMs = totalAfterStopMs
        self.outputChars = outputChars
    }
}

public struct BenchmarkCacheLog: Equatable, Sendable {
    public let base: BenchmarkCaseEventBase
    public let namespace: String?
    public let key: String?
    public let hit: Bool
    public let keyMaterialRef: BenchmarkArtifactRef?
    public let error: String?

    public init(
        base: BenchmarkCaseEventBase,
        namespace: String?,
        key: String?,
        hit: Bool,
        keyMaterialRef: BenchmarkArtifactRef?,
        error: String?
    ) {
        self.base = base
        self.namespace = namespace
        self.key = key
        self.hit = hit
        self.keyMaterialRef = keyMaterialRef
        self.error = error
    }
}

public struct BenchmarkErrorLog: Equatable, Sendable {
    public let base: BenchmarkCaseEventBase
    public let originStage: BenchmarkEventStage?
    public let errorType: String?
    public let message: String

    public init(
        base: BenchmarkCaseEventBase,
        originStage: BenchmarkEventStage?,
        errorType: String?,
        message: String
    ) {
        self.base = base
        self.originStage = originStage
        self.errorType = errorType
        self.message = message
    }
}

public struct BenchmarkArtifactWriteFailedLog: Equatable, Sendable {
    public let base: BenchmarkCaseEventBase
    public let relativePath: String
    public let message: String

    public init(base: BenchmarkCaseEventBase, relativePath: String, message: String) {
        self.base = base
        self.relativePath = relativePath
        self.message = message
    }
}

public enum BenchmarkCaseEvent: Equatable, Sendable {
    case loadCase(BenchmarkLoadCaseLog)
    case audioReplay(BenchmarkAudioReplayLog)
    case stt(BenchmarkSTTLog)
    case context(BenchmarkContextLog)
    case generation(BenchmarkGenerationLog)
    case judge(BenchmarkJudgeLog)
    case aggregate(BenchmarkAggregateLog)
    case cache(BenchmarkCacheLog)
    case error(BenchmarkErrorLog)
    case artifactWriteFailed(BenchmarkArtifactWriteFailedLog)
}

public extension BenchmarkCaseEvent {
    var base: BenchmarkCaseEventBase {
        switch self {
        case let .loadCase(log):
            return log.base
        case let .audioReplay(log):
            return log.base
        case let .stt(log):
            return log.base
        case let .context(log):
            return log.base
        case let .generation(log):
            return log.base
        case let .judge(log):
            return log.base
        case let .aggregate(log):
            return log.base
        case let .cache(log):
            return log.base
        case let .error(log):
            return log.base
        case let .artifactWriteFailed(log):
            return log.base
        }
    }
}

extension BenchmarkCaseEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case caseID = "case_id"
        case stage
        case status
        case startedAtMs = "started_at_ms"
        case endedAtMs = "ended_at_ms"
        case recordedAtMs = "recorded_at_ms"
        case attrs
    }

    private enum AttrKeys: String, CodingKey {
        case transcriptSource = "transcript_source"
        case inputSource = "input_source"
        case referenceSource = "reference_source"
        case intentSource = "intent_source"
        case contextPresent = "context_present"
        case visionImagePresent = "vision_image_present"
        case audioFilePath = "audio_file_path"
        case rawRowRef = "raw_row_ref"

        case profile
        case chunkMs = "chunk_ms"
        case realtime

        case provider
        case mode
        case transcriptText = "stt_text"
        case referenceText = "reference_text"
        case transcriptChars = "transcript_chars"
        case cer
        case sttTotalMs = "stt_total_ms"
        case sttAfterStopMs = "stt_after_stop_ms"
        case attempts
        case rawResponseRef = "raw_response_ref"

        case sourceChars = "source_chars"
        case summaryChars = "summary_chars"
        case termsCount = "terms_count"
        case rawContextRef = "raw_context_ref"

        case model
        case inputChars = "input_chars"
        case outputChars = "output_chars"
        case postMs = "post_ms"
        case promptRef = "prompt_ref"
        case responseRef = "response_ref"

        case match
        case score
        case intentPreservationScore = "intent_preservation_score"
        case hallucinationScore = "hallucination_score"
        case hallucinationRate = "hallucination_rate"
        case requestRef = "request_ref"

        case exactMatch = "exact_match"
        case intentMatch = "intent_match"
        case intentScore = "intent_score"
        case latencyMs = "latency_ms"
        case totalAfterStopMs = "total_after_stop_ms"

        case namespace
        case key
        case hit
        case keyMaterialRef = "key_material_ref"

        case originStage = "origin_stage"
        case errorType = "error_type"
        case message
        case error

        case relativePath = "relative_path"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stage = try container.decode(BenchmarkEventStage.self, forKey: .stage)
        let base = BenchmarkCaseEventBase(
            runID: try container.decode(String.self, forKey: .runID),
            caseID: try container.decode(String.self, forKey: .caseID),
            stage: stage,
            status: try container.decode(BenchmarkEventStatus.self, forKey: .status),
            startedAtMs: try container.decode(Int64.self, forKey: .startedAtMs),
            endedAtMs: try container.decode(Int64.self, forKey: .endedAtMs),
            recordedAtMs: try container.decode(Int64.self, forKey: .recordedAtMs)
        )
        let attrs = try container.nestedContainer(keyedBy: AttrKeys.self, forKey: .attrs)

        switch stage {
        case .loadCase:
            self = .loadCase(BenchmarkLoadCaseLog(
                base: base,
                sources: BenchmarkReferenceSources(
                    transcript: try attrs.decodeIfPresent(String.self, forKey: .transcriptSource),
                    input: try attrs.decodeIfPresent(String.self, forKey: .inputSource),
                    reference: try attrs.decodeIfPresent(String.self, forKey: .referenceSource),
                    intent: try attrs.decodeIfPresent(String.self, forKey: .intentSource)
                ),
                contextPresent: try attrs.decode(Bool.self, forKey: .contextPresent),
                visionImagePresent: try attrs.decode(Bool.self, forKey: .visionImagePresent),
                audioFilePath: try attrs.decodeIfPresent(String.self, forKey: .audioFilePath),
                rawRowRef: try attrs.decodeIfPresent(BenchmarkArtifactRef.self, forKey: .rawRowRef)
            ))
        case .audioReplay:
            self = .audioReplay(BenchmarkAudioReplayLog(
                base: base,
                profile: try attrs.decodeIfPresent(String.self, forKey: .profile) ?? "file_replay_realtime",
                chunkMs: try attrs.decodeIfPresent(Int.self, forKey: .chunkMs),
                realtime: try attrs.decodeIfPresent(Bool.self, forKey: .realtime) ?? true
            ))
        case .stt:
            self = .stt(BenchmarkSTTLog(
                base: base,
                provider: try attrs.decodeIfPresent(String.self, forKey: .provider),
                mode: try attrs.decodeIfPresent(String.self, forKey: .mode),
                transcriptText: try attrs.decodeIfPresent(String.self, forKey: .transcriptText),
                referenceText: try attrs.decodeIfPresent(String.self, forKey: .referenceText),
                transcriptChars: try attrs.decodeIfPresent(Int.self, forKey: .transcriptChars),
                cer: try attrs.decodeIfPresent(Double.self, forKey: .cer),
                sttTotalMs: try attrs.decodeIfPresent(Double.self, forKey: .sttTotalMs),
                sttAfterStopMs: try attrs.decodeIfPresent(Double.self, forKey: .sttAfterStopMs),
                attempts: try attrs.decodeIfPresent([BenchmarkSTTAttempt].self, forKey: .attempts),
                rawResponseRef: try attrs.decodeIfPresent(BenchmarkArtifactRef.self, forKey: .rawResponseRef),
                error: try attrs.decodeIfPresent(String.self, forKey: .error)
            ))
        case .context:
            self = .context(BenchmarkContextLog(
                base: base,
                contextPresent: try attrs.decode(Bool.self, forKey: .contextPresent),
                sourceChars: try attrs.decodeIfPresent(Int.self, forKey: .sourceChars),
                summaryChars: try attrs.decodeIfPresent(Int.self, forKey: .summaryChars),
                termsCount: try attrs.decodeIfPresent(Int.self, forKey: .termsCount),
                rawContextRef: try attrs.decodeIfPresent(BenchmarkArtifactRef.self, forKey: .rawContextRef),
                error: try attrs.decodeIfPresent(String.self, forKey: .error)
            ))
        case .generation:
            self = .generation(BenchmarkGenerationLog(
                base: base,
                model: try attrs.decodeIfPresent(String.self, forKey: .model),
                inputChars: try attrs.decodeIfPresent(Int.self, forKey: .inputChars),
                outputChars: try attrs.decodeIfPresent(Int.self, forKey: .outputChars),
                postMs: try attrs.decodeIfPresent(Double.self, forKey: .postMs),
                promptRef: try attrs.decodeIfPresent(BenchmarkArtifactRef.self, forKey: .promptRef),
                responseRef: try attrs.decodeIfPresent(BenchmarkArtifactRef.self, forKey: .responseRef),
                error: try attrs.decodeIfPresent(String.self, forKey: .error)
            ))
        case .judge:
            self = .judge(BenchmarkJudgeLog(
                base: base,
                model: try attrs.decodeIfPresent(String.self, forKey: .model),
                match: try attrs.decodeIfPresent(Bool.self, forKey: .match),
                score: try attrs.decodeIfPresent(Int.self, forKey: .score),
                intentPreservationScore: try attrs.decodeIfPresent(Double.self, forKey: .intentPreservationScore),
                hallucinationScore: try attrs.decodeIfPresent(Double.self, forKey: .hallucinationScore),
                hallucinationRate: try attrs.decodeIfPresent(Double.self, forKey: .hallucinationRate),
                requestRef: try attrs.decodeIfPresent(BenchmarkArtifactRef.self, forKey: .requestRef),
                responseRef: try attrs.decodeIfPresent(BenchmarkArtifactRef.self, forKey: .responseRef),
                error: try attrs.decodeIfPresent(String.self, forKey: .error)
            ))
        case .aggregate:
            self = .aggregate(BenchmarkAggregateLog(
                base: base,
                exactMatch: try attrs.decodeIfPresent(Bool.self, forKey: .exactMatch),
                cer: try attrs.decodeIfPresent(Double.self, forKey: .cer),
                intentMatch: try attrs.decodeIfPresent(Bool.self, forKey: .intentMatch),
                intentScore: try attrs.decodeIfPresent(Int.self, forKey: .intentScore),
                intentPreservationScore: try attrs.decodeIfPresent(Double.self, forKey: .intentPreservationScore),
                hallucinationScore: try attrs.decodeIfPresent(Double.self, forKey: .hallucinationScore),
                hallucinationRate: try attrs.decodeIfPresent(Double.self, forKey: .hallucinationRate),
                latencyMs: try attrs.decodeIfPresent(Double.self, forKey: .latencyMs),
                totalAfterStopMs: try attrs.decodeIfPresent(Double.self, forKey: .totalAfterStopMs),
                outputChars: try attrs.decodeIfPresent(Int.self, forKey: .outputChars)
            ))
        case .cache:
            self = .cache(BenchmarkCacheLog(
                base: base,
                namespace: try attrs.decodeIfPresent(String.self, forKey: .namespace),
                key: try attrs.decodeIfPresent(String.self, forKey: .key),
                hit: try attrs.decode(Bool.self, forKey: .hit),
                keyMaterialRef: try attrs.decodeIfPresent(BenchmarkArtifactRef.self, forKey: .keyMaterialRef),
                error: try attrs.decodeIfPresent(String.self, forKey: .error)
            ))
        case .error:
            self = .error(BenchmarkErrorLog(
                base: base,
                originStage: try attrs.decodeIfPresent(BenchmarkEventStage.self, forKey: .originStage),
                errorType: try attrs.decodeIfPresent(String.self, forKey: .errorType),
                message: try attrs.decode(String.self, forKey: .message)
            ))
        case .artifactWriteFailed:
            self = .artifactWriteFailed(BenchmarkArtifactWriteFailedLog(
                base: base,
                relativePath: try attrs.decode(String.self, forKey: .relativePath),
                message: try attrs.decode(String.self, forKey: .message)
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let base = base
        try container.encode(base.runID, forKey: .runID)
        try container.encode(base.caseID, forKey: .caseID)
        try container.encode(base.stage, forKey: .stage)
        try container.encode(base.status, forKey: .status)
        try container.encode(base.startedAtMs, forKey: .startedAtMs)
        try container.encode(base.endedAtMs, forKey: .endedAtMs)
        try container.encode(base.recordedAtMs, forKey: .recordedAtMs)

        var attrs = container.nestedContainer(keyedBy: AttrKeys.self, forKey: .attrs)
        switch self {
        case let .loadCase(log):
            try attrs.encodeIfPresent(log.sources.transcript, forKey: .transcriptSource)
            try attrs.encodeIfPresent(log.sources.input, forKey: .inputSource)
            try attrs.encodeIfPresent(log.sources.reference, forKey: .referenceSource)
            try attrs.encodeIfPresent(log.sources.intent, forKey: .intentSource)
            try attrs.encode(log.contextPresent, forKey: .contextPresent)
            try attrs.encode(log.visionImagePresent, forKey: .visionImagePresent)
            try attrs.encodeIfPresent(log.audioFilePath, forKey: .audioFilePath)
            try attrs.encodeIfPresent(log.rawRowRef, forKey: .rawRowRef)
        case let .audioReplay(log):
            try attrs.encode(log.profile, forKey: .profile)
            try attrs.encodeIfPresent(log.chunkMs, forKey: .chunkMs)
            try attrs.encode(log.realtime, forKey: .realtime)
        case let .stt(log):
            try attrs.encodeIfPresent(log.provider, forKey: .provider)
            try attrs.encodeIfPresent(log.mode, forKey: .mode)
            try attrs.encodeIfPresent(log.transcriptText, forKey: .transcriptText)
            try attrs.encodeIfPresent(log.referenceText, forKey: .referenceText)
            try attrs.encodeIfPresent(log.transcriptChars, forKey: .transcriptChars)
            try attrs.encodeIfPresent(log.cer, forKey: .cer)
            try attrs.encodeIfPresent(log.sttTotalMs, forKey: .sttTotalMs)
            try attrs.encodeIfPresent(log.sttAfterStopMs, forKey: .sttAfterStopMs)
            try attrs.encodeIfPresent(log.attempts, forKey: .attempts)
            try attrs.encodeIfPresent(log.rawResponseRef, forKey: .rawResponseRef)
            try attrs.encodeIfPresent(log.error, forKey: .error)
        case let .context(log):
            try attrs.encode(log.contextPresent, forKey: .contextPresent)
            try attrs.encodeIfPresent(log.sourceChars, forKey: .sourceChars)
            try attrs.encodeIfPresent(log.summaryChars, forKey: .summaryChars)
            try attrs.encodeIfPresent(log.termsCount, forKey: .termsCount)
            try attrs.encodeIfPresent(log.rawContextRef, forKey: .rawContextRef)
            try attrs.encodeIfPresent(log.error, forKey: .error)
        case let .generation(log):
            try attrs.encodeIfPresent(log.model, forKey: .model)
            try attrs.encodeIfPresent(log.inputChars, forKey: .inputChars)
            try attrs.encodeIfPresent(log.outputChars, forKey: .outputChars)
            try attrs.encodeIfPresent(log.postMs, forKey: .postMs)
            try attrs.encodeIfPresent(log.promptRef, forKey: .promptRef)
            try attrs.encodeIfPresent(log.responseRef, forKey: .responseRef)
            try attrs.encodeIfPresent(log.error, forKey: .error)
        case let .judge(log):
            try attrs.encodeIfPresent(log.model, forKey: .model)
            try attrs.encodeIfPresent(log.match, forKey: .match)
            try attrs.encodeIfPresent(log.score, forKey: .score)
            try attrs.encodeIfPresent(log.intentPreservationScore, forKey: .intentPreservationScore)
            try attrs.encodeIfPresent(log.hallucinationScore, forKey: .hallucinationScore)
            try attrs.encodeIfPresent(log.hallucinationRate, forKey: .hallucinationRate)
            try attrs.encodeIfPresent(log.requestRef, forKey: .requestRef)
            try attrs.encodeIfPresent(log.responseRef, forKey: .responseRef)
            try attrs.encodeIfPresent(log.error, forKey: .error)
        case let .aggregate(log):
            try attrs.encodeIfPresent(log.exactMatch, forKey: .exactMatch)
            try attrs.encodeIfPresent(log.cer, forKey: .cer)
            try attrs.encodeIfPresent(log.intentMatch, forKey: .intentMatch)
            try attrs.encodeIfPresent(log.intentScore, forKey: .intentScore)
            try attrs.encodeIfPresent(log.intentPreservationScore, forKey: .intentPreservationScore)
            try attrs.encodeIfPresent(log.hallucinationScore, forKey: .hallucinationScore)
            try attrs.encodeIfPresent(log.hallucinationRate, forKey: .hallucinationRate)
            try attrs.encodeIfPresent(log.latencyMs, forKey: .latencyMs)
            try attrs.encodeIfPresent(log.totalAfterStopMs, forKey: .totalAfterStopMs)
            try attrs.encodeIfPresent(log.outputChars, forKey: .outputChars)
        case let .cache(log):
            try attrs.encodeIfPresent(log.namespace, forKey: .namespace)
            try attrs.encodeIfPresent(log.key, forKey: .key)
            try attrs.encode(log.hit, forKey: .hit)
            try attrs.encodeIfPresent(log.keyMaterialRef, forKey: .keyMaterialRef)
            try attrs.encodeIfPresent(log.error, forKey: .error)
        case let .error(log):
            try attrs.encodeIfPresent(log.originStage, forKey: .originStage)
            try attrs.encodeIfPresent(log.errorType, forKey: .errorType)
            try attrs.encode(log.message, forKey: .message)
        case let .artifactWriteFailed(log):
            try attrs.encode(log.relativePath, forKey: .relativePath)
            try attrs.encode(log.message, forKey: .message)
        }
    }
}
