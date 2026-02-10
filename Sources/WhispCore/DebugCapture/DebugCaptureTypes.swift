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
    public let promptText: String

    public init(
        stage: String,
        model: String,
        promptChars: Int,
        promptFilePath: String,
        metaFilePath: String,
        contextSummaryChars: Int,
        contextTermsCount: Int,
        contextAccessibilityChars: Int,
        promptText: String
    ) {
        self.stage = stage
        self.model = model
        self.promptChars = promptChars
        self.promptFilePath = promptFilePath
        self.metaFilePath = metaFilePath
        self.contextSummaryChars = contextSummaryChars
        self.contextTermsCount = contextTermsCount
        self.contextAccessibilityChars = contextAccessibilityChars
        self.promptText = promptText
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
    public let focusedElement: AccessibilityElementSnapshot?
    public let error: String?

    public init(
        capturedAt: String,
        trusted: Bool,
        appName: String? = nil,
        bundleID: String? = nil,
        processID: Int32? = nil,
        windowTitle: String? = nil,
        focusedElement: AccessibilityElementSnapshot? = nil,
        error: String? = nil
    ) {
        self.capturedAt = capturedAt
        self.trusted = trusted
        self.appName = appName
        self.bundleID = bundleID
        self.processID = processID
        self.windowTitle = windowTitle
        self.focusedElement = focusedElement
        self.error = error
    }
}

public struct DebugRunEvent: Codable, Equatable, Sendable {
    public let timestamp: String
    public let event: String
    public let fields: [String: String]

    public init(timestamp: String, event: String, fields: [String: String]) {
        self.timestamp = timestamp
        self.event = event
        self.fields = fields
    }
}

public struct DebugCaptureRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let runID: String
    public let createdAt: String
    public let runDirectoryPath: String
    public let promptsDirectoryPath: String
    public let eventsFilePath: String
    public let audioFilePath: String
    public let sampleRate: Int

    public var sttText: String?
    public var outputText: String?
    public var llmModel: String
    public var appName: String?
    public var status: String
    public var errorMessage: String?
    public var groundTruthText: String?
    public var context: ContextInfo?
    public var accessibilitySnapshot: AccessibilitySnapshot?
    public var visionImageFilePath: String?
    public var visionImageMimeType: String?

    public init(
        id: String,
        runID: String,
        createdAt: String,
        runDirectoryPath: String,
        promptsDirectoryPath: String,
        eventsFilePath: String,
        audioFilePath: String,
        sampleRate: Int,
        sttText: String? = nil,
        outputText: String? = nil,
        llmModel: String,
        appName: String?,
        status: String,
        errorMessage: String? = nil,
        groundTruthText: String? = nil,
        context: ContextInfo? = nil,
        accessibilitySnapshot: AccessibilitySnapshot? = nil,
        visionImageFilePath: String? = nil,
        visionImageMimeType: String? = nil
    ) {
        self.id = id
        self.runID = runID
        self.createdAt = createdAt
        self.runDirectoryPath = runDirectoryPath
        self.promptsDirectoryPath = promptsDirectoryPath
        self.eventsFilePath = eventsFilePath
        self.audioFilePath = audioFilePath
        self.sampleRate = sampleRate
        self.sttText = sttText
        self.outputText = outputText
        self.llmModel = llmModel
        self.appName = appName
        self.status = status
        self.errorMessage = errorMessage
        self.groundTruthText = groundTruthText
        self.context = context
        self.accessibilitySnapshot = accessibilitySnapshot
        self.visionImageFilePath = visionImageFilePath
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
