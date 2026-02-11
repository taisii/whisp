import Foundation

public enum BenchmarkKind: String, Codable, CaseIterable, Sendable {
    case stt
    case generation
    case vision
    case e2e
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

public struct BenchmarkCaseMetrics: Codable, Equatable, Sendable {
    public var exactMatch: Bool?
    public var cer: Double?
    public var termPrecision: Double?
    public var termRecall: Double?
    public var termF1: Double?
    public var intentMatch: Bool?
    public var intentScore: Int?
    public var sttTotalMs: Double?
    public var sttAfterStopMs: Double?
    public var postMs: Double?
    public var totalAfterStopMs: Double?
    public var latencyMs: Double?
    public var audioSeconds: Double?
    public var outputChars: Int?

    public init(
        exactMatch: Bool? = nil,
        cer: Double? = nil,
        termPrecision: Double? = nil,
        termRecall: Double? = nil,
        termF1: Double? = nil,
        intentMatch: Bool? = nil,
        intentScore: Int? = nil,
        sttTotalMs: Double? = nil,
        sttAfterStopMs: Double? = nil,
        postMs: Double? = nil,
        totalAfterStopMs: Double? = nil,
        latencyMs: Double? = nil,
        audioSeconds: Double? = nil,
        outputChars: Int? = nil
    ) {
        self.exactMatch = exactMatch
        self.cer = cer
        self.termPrecision = termPrecision
        self.termRecall = termRecall
        self.termF1 = termF1
        self.intentMatch = intentMatch
        self.intentScore = intentScore
        self.sttTotalMs = sttTotalMs
        self.sttAfterStopMs = sttAfterStopMs
        self.postMs = postMs
        self.totalAfterStopMs = totalAfterStopMs
        self.latencyMs = latencyMs
        self.audioSeconds = audioSeconds
        self.outputChars = outputChars
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

public struct BenchmarkRunOptions: Codable, Equatable, Sendable {
    public var sourceCasesPath: String
    public var sttMode: String?
    public var chunkMs: Int?
    public var realtime: Bool?
    public var requireContext: Bool?
    public var minAudioSeconds: Double?
    public var minLabelConfidence: Double?
    public var useCache: Bool?
    public var intentSource: String?
    public var intentJudgeEnabled: Bool?
    public var intentJudgeModel: String?
    public var llmModel: String?
    public var caseLimit: Int?

    public init(
        sourceCasesPath: String,
        sttMode: String? = nil,
        chunkMs: Int? = nil,
        realtime: Bool? = nil,
        requireContext: Bool? = nil,
        minAudioSeconds: Double? = nil,
        minLabelConfidence: Double? = nil,
        useCache: Bool? = nil,
        intentSource: String? = nil,
        intentJudgeEnabled: Bool? = nil,
        intentJudgeModel: String? = nil,
        llmModel: String? = nil,
        caseLimit: Int? = nil
    ) {
        self.sourceCasesPath = sourceCasesPath
        self.sttMode = sttMode
        self.chunkMs = chunkMs
        self.realtime = realtime
        self.requireContext = requireContext
        self.minAudioSeconds = minAudioSeconds
        self.minLabelConfidence = minLabelConfidence
        self.useCache = useCache
        self.intentSource = intentSource
        self.intentJudgeEnabled = intentJudgeEnabled
        self.intentJudgeModel = intentJudgeModel
        self.llmModel = llmModel
        self.caseLimit = caseLimit
    }
}

public struct BenchmarkRunMetrics: Codable, Equatable, Sendable {
    public var casesTotal: Int
    public var casesSelected: Int
    public var executedCases: Int
    public var skippedCases: Int
    public var failedCases: Int
    public var cachedHits: Int

    public var exactMatchRate: Double?
    public var avgCER: Double?
    public var weightedCER: Double?
    public var avgTermsF1: Double?
    public var intentMatchRate: Double?
    public var intentAvgScore: Double?

    public var latencyMs: BenchmarkLatencyDistribution?
    public var afterStopLatencyMs: BenchmarkLatencyDistribution?
    public var postLatencyMs: BenchmarkLatencyDistribution?
    public var totalAfterStopLatencyMs: BenchmarkLatencyDistribution?
    public var cost: BenchmarkCostBreakdown?

    public init(
        casesTotal: Int,
        casesSelected: Int,
        executedCases: Int,
        skippedCases: Int,
        failedCases: Int,
        cachedHits: Int = 0,
        exactMatchRate: Double? = nil,
        avgCER: Double? = nil,
        weightedCER: Double? = nil,
        avgTermsF1: Double? = nil,
        intentMatchRate: Double? = nil,
        intentAvgScore: Double? = nil,
        latencyMs: BenchmarkLatencyDistribution? = nil,
        afterStopLatencyMs: BenchmarkLatencyDistribution? = nil,
        postLatencyMs: BenchmarkLatencyDistribution? = nil,
        totalAfterStopLatencyMs: BenchmarkLatencyDistribution? = nil,
        cost: BenchmarkCostBreakdown? = nil
    ) {
        self.casesTotal = casesTotal
        self.casesSelected = casesSelected
        self.executedCases = executedCases
        self.skippedCases = skippedCases
        self.failedCases = failedCases
        self.cachedHits = cachedHits
        self.exactMatchRate = exactMatchRate
        self.avgCER = avgCER
        self.weightedCER = weightedCER
        self.avgTermsF1 = avgTermsF1
        self.intentMatchRate = intentMatchRate
        self.intentAvgScore = intentAvgScore
        self.latencyMs = latencyMs
        self.afterStopLatencyMs = afterStopLatencyMs
        self.postLatencyMs = postLatencyMs
        self.totalAfterStopLatencyMs = totalAfterStopLatencyMs
        self.cost = cost
    }
}

public struct BenchmarkRunPaths: Codable, Equatable, Sendable {
    public var logDirectoryPath: String
    public var rowsFilePath: String
    public var summaryFilePath: String
    public var casesFilePath: String
    public var eventsFilePath: String
    public var artifactsDirectoryPath: String

    public init(
        logDirectoryPath: String,
        rowsFilePath: String,
        summaryFilePath: String,
        casesFilePath: String,
        eventsFilePath: String,
        artifactsDirectoryPath: String
    ) {
        self.logDirectoryPath = logDirectoryPath
        self.rowsFilePath = rowsFilePath
        self.summaryFilePath = summaryFilePath
        self.casesFilePath = casesFilePath
        self.eventsFilePath = eventsFilePath
        self.artifactsDirectoryPath = artifactsDirectoryPath
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
    public var metrics: BenchmarkRunMetrics
    public var paths: BenchmarkRunPaths

    public init(
        schemaVersion: Int = 2,
        id: String,
        kind: BenchmarkKind,
        status: BenchmarkRunStatus = .completed,
        createdAt: String,
        updatedAt: String,
        options: BenchmarkRunOptions,
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
        self.metrics = metrics
        self.paths = paths
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

public struct BenchmarkSTTLog: Equatable, Sendable {
    public let base: BenchmarkCaseEventBase
    public let provider: String?
    public let mode: String?
    public let transcriptChars: Int?
    public let cer: Double?
    public let sttTotalMs: Double?
    public let sttAfterStopMs: Double?
    public let rawResponseRef: BenchmarkArtifactRef?
    public let error: String?

    public init(
        base: BenchmarkCaseEventBase,
        provider: String?,
        mode: String?,
        transcriptChars: Int?,
        cer: Double?,
        sttTotalMs: Double?,
        sttAfterStopMs: Double?,
        rawResponseRef: BenchmarkArtifactRef?,
        error: String?
    ) {
        self.base = base
        self.provider = provider
        self.mode = mode
        self.transcriptChars = transcriptChars
        self.cer = cer
        self.sttTotalMs = sttTotalMs
        self.sttAfterStopMs = sttAfterStopMs
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
    public let requestRef: BenchmarkArtifactRef?
    public let responseRef: BenchmarkArtifactRef?
    public let error: String?

    public init(
        base: BenchmarkCaseEventBase,
        model: String?,
        match: Bool?,
        score: Int?,
        requestRef: BenchmarkArtifactRef?,
        responseRef: BenchmarkArtifactRef?,
        error: String?
    ) {
        self.base = base
        self.model = model
        self.match = match
        self.score = score
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
    public let latencyMs: Double?
    public let totalAfterStopMs: Double?
    public let outputChars: Int?

    public init(
        base: BenchmarkCaseEventBase,
        exactMatch: Bool?,
        cer: Double?,
        intentMatch: Bool?,
        intentScore: Int?,
        latencyMs: Double?,
        totalAfterStopMs: Double?,
        outputChars: Int?
    ) {
        self.base = base
        self.exactMatch = exactMatch
        self.cer = cer
        self.intentMatch = intentMatch
        self.intentScore = intentScore
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

        case provider
        case mode
        case transcriptChars = "transcript_chars"
        case cer
        case sttTotalMs = "stt_total_ms"
        case sttAfterStopMs = "stt_after_stop_ms"
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
        case .stt:
            self = .stt(BenchmarkSTTLog(
                base: base,
                provider: try attrs.decodeIfPresent(String.self, forKey: .provider),
                mode: try attrs.decodeIfPresent(String.self, forKey: .mode),
                transcriptChars: try attrs.decodeIfPresent(Int.self, forKey: .transcriptChars),
                cer: try attrs.decodeIfPresent(Double.self, forKey: .cer),
                sttTotalMs: try attrs.decodeIfPresent(Double.self, forKey: .sttTotalMs),
                sttAfterStopMs: try attrs.decodeIfPresent(Double.self, forKey: .sttAfterStopMs),
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
        case let .stt(log):
            try attrs.encodeIfPresent(log.provider, forKey: .provider)
            try attrs.encodeIfPresent(log.mode, forKey: .mode)
            try attrs.encodeIfPresent(log.transcriptChars, forKey: .transcriptChars)
            try attrs.encodeIfPresent(log.cer, forKey: .cer)
            try attrs.encodeIfPresent(log.sttTotalMs, forKey: .sttTotalMs)
            try attrs.encodeIfPresent(log.sttAfterStopMs, forKey: .sttAfterStopMs)
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
            try attrs.encodeIfPresent(log.requestRef, forKey: .requestRef)
            try attrs.encodeIfPresent(log.responseRef, forKey: .responseRef)
            try attrs.encodeIfPresent(log.error, forKey: .error)
        case let .aggregate(log):
            try attrs.encodeIfPresent(log.exactMatch, forKey: .exactMatch)
            try attrs.encodeIfPresent(log.cer, forKey: .cer)
            try attrs.encodeIfPresent(log.intentMatch, forKey: .intentMatch)
            try attrs.encodeIfPresent(log.intentScore, forKey: .intentScore)
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
