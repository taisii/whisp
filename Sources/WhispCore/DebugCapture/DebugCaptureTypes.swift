import Foundation

public struct DebugPromptSnapshot: Codable, Equatable, Sendable {
    public let stage: String
    public let model: String
    public let promptChars: Int
    public let promptFilePath: String
    public let metaFilePath: String
    public let contextSummaryChars: Int
    public let contextTermsCount: Int
    public let contextAccessibilityChars: Int
    public let context: ContextInfo?
    public let promptText: String
    public let responseText: String

    public init(
        stage: String,
        model: String,
        promptChars: Int,
        promptFilePath: String,
        metaFilePath: String,
        contextSummaryChars: Int,
        contextTermsCount: Int,
        contextAccessibilityChars: Int,
        context: ContextInfo? = nil,
        promptText: String,
        responseText: String
    ) {
        self.stage = stage
        self.model = model
        self.promptChars = promptChars
        self.promptFilePath = promptFilePath
        self.metaFilePath = metaFilePath
        self.contextSummaryChars = contextSummaryChars
        self.contextTermsCount = contextTermsCount
        self.contextAccessibilityChars = contextAccessibilityChars
        self.context = context
        self.promptText = promptText
        self.responseText = responseText
    }
}

public struct AccessibilityTextRange: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct AccessibilityElementSnapshot: Codable, Equatable, Sendable {
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let elementDescription: String?
    public let help: String?
    public let placeholder: String?
    public let value: String?
    public let valueChars: Int
    public let selectedText: String?
    public let selectedRange: AccessibilityTextRange?
    public let insertionPointLineNumber: Int?
    public let labelTexts: [String]
    public let caretContext: String?
    public let caretContextRange: AccessibilityTextRange?

    public init(
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        elementDescription: String? = nil,
        help: String? = nil,
        placeholder: String? = nil,
        value: String? = nil,
        valueChars: Int = 0,
        selectedText: String? = nil,
        selectedRange: AccessibilityTextRange? = nil,
        insertionPointLineNumber: Int? = nil,
        labelTexts: [String] = [],
        caretContext: String? = nil,
        caretContextRange: AccessibilityTextRange? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.elementDescription = elementDescription
        self.help = help
        self.placeholder = placeholder
        self.value = value
        self.valueChars = valueChars
        self.selectedText = selectedText
        self.selectedRange = selectedRange
        self.insertionPointLineNumber = insertionPointLineNumber
        self.labelTexts = labelTexts
        self.caretContext = caretContext
        self.caretContextRange = caretContextRange
    }
}

public struct AccessibilitySnapshot: Codable, Equatable, Sendable {
    public let capturedAt: String
    public let trusted: Bool
    public let appName: String?
    public let bundleID: String?
    public let processID: Int32?
    public let windowTitle: String?
    public let windowText: String?
    public let windowTextChars: Int
    public let focusedElement: AccessibilityElementSnapshot?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case capturedAt
        case trusted
        case appName
        case bundleID
        case processID
        case windowTitle
        case windowText
        case windowTextChars
        case focusedElement
        case error
    }

    public init(
        capturedAt: String,
        trusted: Bool,
        appName: String? = nil,
        bundleID: String? = nil,
        processID: Int32? = nil,
        windowTitle: String? = nil,
        windowText: String? = nil,
        windowTextChars: Int = 0,
        focusedElement: AccessibilityElementSnapshot? = nil,
        error: String? = nil
    ) {
        self.capturedAt = capturedAt
        self.trusted = trusted
        self.appName = appName
        self.bundleID = bundleID
        self.processID = processID
        self.windowTitle = windowTitle
        self.windowText = windowText
        self.windowTextChars = windowTextChars
        self.focusedElement = focusedElement
        self.error = error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try container.decode(String.self, forKey: .capturedAt)
        trusted = try container.decode(Bool.self, forKey: .trusted)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        processID = try container.decodeIfPresent(Int32.self, forKey: .processID)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        windowText = try container.decodeIfPresent(String.self, forKey: .windowText)
        windowTextChars = try container.decodeIfPresent(Int.self, forKey: .windowTextChars) ?? 0
        focusedElement = try container.decodeIfPresent(AccessibilityElementSnapshot.self, forKey: .focusedElement)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(trusted, forKey: .trusted)
        try container.encodeIfPresent(appName, forKey: .appName)
        try container.encodeIfPresent(bundleID, forKey: .bundleID)
        try container.encodeIfPresent(processID, forKey: .processID)
        try container.encodeIfPresent(windowTitle, forKey: .windowTitle)
        try container.encodeIfPresent(windowText, forKey: .windowText)
        try container.encode(windowTextChars, forKey: .windowTextChars)
        try container.encodeIfPresent(focusedElement, forKey: .focusedElement)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

public struct DebugCaptureRecord: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let runID: String
    public let createdAt: String
    public let runDirectoryPath: String
    public let promptsDirectoryPath: String
    public let eventsFilePath: String
    public let audioFilePath: String
    public let sampleRate: Int
    public var skipReason: String?
    public var failure: DebugRunFailure?
    public var texts: DebugRunTexts
    public var metrics: DebugRunMetrics
    public var artifacts: DebugRunArtifactsSummary

    public var sttText: String?
    public var outputText: String?
    public var llmModel: String
    public var appName: String?
    public var status: String
    public var errorMessage: String?
    public var groundTruthText: String?
    public var sttGroundTruthText: String?
    public var context: ContextInfo?
    public var accessibilitySnapshot: AccessibilitySnapshot?
    public var visionImageFilePath: String?
    public var visionImageMimeType: String?

    public init(
        schemaVersion: Int = 2,
        id: String,
        runID: String,
        createdAt: String,
        runDirectoryPath: String,
        promptsDirectoryPath: String,
        eventsFilePath: String,
        audioFilePath: String,
        sampleRate: Int,
        skipReason: String? = nil,
        failure: DebugRunFailure? = nil,
        texts: DebugRunTexts = DebugRunTexts(),
        metrics: DebugRunMetrics = DebugRunMetrics(),
        artifacts: DebugRunArtifactsSummary = DebugRunArtifactsSummary(),
        sttText: String? = nil,
        outputText: String? = nil,
        llmModel: String,
        appName: String?,
        status: String,
        errorMessage: String? = nil,
        groundTruthText: String? = nil,
        sttGroundTruthText: String? = nil,
        context: ContextInfo? = nil,
        accessibilitySnapshot: AccessibilitySnapshot? = nil,
        visionImageFilePath: String? = nil,
        visionImageMimeType: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.runID = runID
        self.createdAt = createdAt
        self.runDirectoryPath = runDirectoryPath
        self.promptsDirectoryPath = promptsDirectoryPath
        self.eventsFilePath = eventsFilePath
        self.audioFilePath = audioFilePath
        self.sampleRate = sampleRate
        self.skipReason = skipReason
        self.failure = failure
        self.texts = texts
        self.metrics = metrics
        self.artifacts = artifacts
        self.sttText = sttText
        self.outputText = outputText
        self.llmModel = llmModel
        self.appName = appName
        self.status = status
        self.errorMessage = errorMessage
        self.groundTruthText = groundTruthText
        self.sttGroundTruthText = sttGroundTruthText
        self.context = context
        self.accessibilitySnapshot = accessibilitySnapshot
        self.visionImageFilePath = visionImageFilePath
        self.visionImageMimeType = visionImageMimeType
    }
}

public struct DebugRunFailure: Codable, Equatable, Sendable {
    public var stage: String
    public var message: String

    public init(stage: String = "", message: String = "") {
        self.stage = stage
        self.message = message
    }
}

public struct DebugRunTexts: Codable, Equatable, Sendable {
    public var stt: String?
    public var output: String?

    public init(stt: String? = nil, output: String? = nil) {
        self.stt = stt
        self.output = output
    }
}

public struct DebugRunMetrics: Codable, Equatable, Sendable {
    public var recordingMs: Double?
    public var sttMs: Double?
    public var postProcessMs: Double?
    public var directInputMs: Double?
    public var pipelineMs: Double?
    public var sttChars: Int
    public var outputChars: Int

    public init(
        recordingMs: Double? = nil,
        sttMs: Double? = nil,
        postProcessMs: Double? = nil,
        directInputMs: Double? = nil,
        pipelineMs: Double? = nil,
        sttChars: Int = 0,
        outputChars: Int = 0
    ) {
        self.recordingMs = recordingMs
        self.sttMs = sttMs
        self.postProcessMs = postProcessMs
        self.directInputMs = directInputMs
        self.pipelineMs = pipelineMs
        self.sttChars = sttChars
        self.outputChars = outputChars
    }
}

public struct DebugRunArtifactsSummary: Codable, Equatable, Sendable {
    public var audioFile: String?
    public var eventsFile: String?
    public var promptsDirectory: String?
    public var visionImageFile: String?
    public var visionImageMimeType: String?

    public init(
        audioFile: String? = nil,
        eventsFile: String? = nil,
        promptsDirectory: String? = nil,
        visionImageFile: String? = nil,
        visionImageMimeType: String? = nil
    ) {
        self.audioFile = audioFile
        self.eventsFile = eventsFile
        self.promptsDirectory = promptsDirectory
        self.visionImageFile = visionImageFile
        self.visionImageMimeType = visionImageMimeType
    }
}

public struct DebugCaptureDetails: Sendable {
    public let record: DebugCaptureRecord
    public let prompts: [DebugPromptSnapshot]

    public init(record: DebugCaptureRecord, prompts: [DebugPromptSnapshot]) {
        self.record = record
        self.prompts = prompts
    }
}
