import Foundation

public struct PromptTraceReference: Sendable {
    public let traceID: String
    public let traceDirectoryPath: String
    public let responseTextFilePath: String
    public let responseMetaFilePath: String

    public init(
        traceID: String,
        traceDirectoryPath: String,
        responseTextFilePath: String,
        responseMetaFilePath: String
    ) {
        self.traceID = traceID
        self.traceDirectoryPath = traceDirectoryPath
        self.responseTextFilePath = responseTextFilePath
        self.responseMetaFilePath = responseMetaFilePath
    }
}

public struct PromptTraceRequestRecord: Codable, Sendable {
    public let traceID: String
    public let timestamp: String
    public let stage: String
    public let model: String
    public let appName: String?
    public let context: ContextInfo?
    public let requestChars: Int
    public let extra: [String: String]

    public init(
        traceID: String,
        timestamp: String,
        stage: String,
        model: String,
        appName: String?,
        context: ContextInfo?,
        requestChars: Int,
        extra: [String: String]
    ) {
        self.traceID = traceID
        self.timestamp = timestamp
        self.stage = stage
        self.model = model
        self.appName = appName
        self.context = context
        self.requestChars = requestChars
        self.extra = extra
    }
}

public struct PromptTraceUsageRecord: Codable, Sendable {
    public let model: String
    public let promptTokens: Int
    public let completionTokens: Int
    public let provider: String

    public init(
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        provider: String
    ) {
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.provider = provider
    }

    init(usage: LLMUsage) {
        self.init(
            model: usage.model,
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            provider: usage.provider
        )
    }
}

public enum PromptTraceResponseStatus: String, Codable, Sendable {
    case ok
    case error
}

public struct PromptTraceResponseRecord: Codable, Sendable {
    public let traceID: String
    public let timestamp: String
    public let status: PromptTraceResponseStatus
    public let responseChars: Int
    public let errorMessage: String?
    public let usage: PromptTraceUsageRecord?

    public init(
        traceID: String,
        timestamp: String,
        status: PromptTraceResponseStatus,
        responseChars: Int,
        errorMessage: String? = nil,
        usage: PromptTraceUsageRecord? = nil
    ) {
        self.traceID = traceID
        self.timestamp = timestamp
        self.status = status
        self.responseChars = responseChars
        self.errorMessage = errorMessage
        self.usage = usage
    }
}

public enum PromptTrace {
    public static var directoryPath: String {
        resolvedDirectoryPath(environment: ProcessInfo.processInfo.environment)
    }

    static func resolvedDirectoryPath(environment: [String: String]) -> String {
        let raw = environment["WHISP_PROMPT_TRACE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty {
            return raw
        }
        return (try? WhispPaths(environment: environment, allowTemporaryFallback: true).promptDefaultDirectory.path)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("whisp-prompts", isDirectory: true)
            .path
    }

    @discardableResult
    public static func dump(
        stage: String,
        model: String,
        appName: String?,
        context: ContextInfo?,
        prompt: String,
        extra: [String: String] = [:]
    ) -> PromptTraceReference? {
        let runDirOverride = extra["run_dir"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetDirectoryPath: String
        if let runDirOverride, !runDirOverride.isEmpty {
            targetDirectoryPath = URL(fileURLWithPath: runDirOverride, isDirectory: true)
                .appendingPathComponent("prompts", isDirectory: true)
                .path
        } else {
            targetDirectoryPath = directoryPath
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeStage = sanitizeFileToken(stage)
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let traceID = "\(timestamp.replacingOccurrences(of: ":", with: "-"))-\(safeStage)-\(id)"

        let promptsDirURL = URL(fileURLWithPath: targetDirectoryPath, isDirectory: true)
        let traceDirURL = promptsDirURL.appendingPathComponent(traceID, isDirectory: true)
        let requestTextURL = traceDirURL.appendingPathComponent("request.txt", isDirectory: false)
        let requestMetaURL = traceDirURL.appendingPathComponent("request.json", isDirectory: false)
        let responseTextURL = traceDirURL.appendingPathComponent("response.txt", isDirectory: false)
        let responseMetaURL = traceDirURL.appendingPathComponent("response.json", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: traceDirURL, withIntermediateDirectories: true)
            try prompt.write(to: requestTextURL, atomically: true, encoding: .utf8)

            let record = PromptTraceRequestRecord(
                traceID: traceID,
                timestamp: timestamp,
                stage: stage,
                model: model,
                appName: appName,
                context: context,
                requestChars: prompt.count,
                extra: extra
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: requestMetaURL, options: [.atomic])
            return PromptTraceReference(
                traceID: traceID,
                traceDirectoryPath: traceDirURL.path,
                responseTextFilePath: responseTextURL.path,
                responseMetaFilePath: responseMetaURL.path
            )
        } catch {
            // Ignore prompt trace failures to avoid affecting app flow.
            return nil
        }
    }

    public static func writeResponse(_ response: String, usage: LLMUsage?, reference: PromptTraceReference?) {
        writeResponseRecord(
            response: response,
            status: .ok,
            usage: usage,
            errorMessage: nil,
            reference: reference
        )
    }

    public static func writeFailure(_ errorMessage: String, reference: PromptTraceReference?) {
        writeResponseRecord(
            response: "",
            status: .error,
            usage: nil,
            errorMessage: errorMessage,
            reference: reference
        )
    }

    private static func writeResponseRecord(
        response: String,
        status: PromptTraceResponseStatus,
        usage: LLMUsage?,
        errorMessage: String?,
        reference: PromptTraceReference?
    ) {
        guard let reference else {
            return
        }
        do {
            try response.write(
                to: URL(fileURLWithPath: reference.responseTextFilePath, isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
            let responseRecord = PromptTraceResponseRecord(
                traceID: reference.traceID,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                status: status,
                responseChars: response.count,
                errorMessage: errorMessage,
                usage: usage.map(PromptTraceUsageRecord.init(usage:))
            )
            let data = try JSONEncoder().encode(responseRecord)
            try data.write(
                to: URL(fileURLWithPath: reference.responseMetaFilePath, isDirectory: false),
                options: [.atomic]
            )
        } catch {
            // Ignore prompt trace failures to avoid affecting app flow.
        }
    }

    private static func sanitizeFileToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let result = String(scalars)
        return result.isEmpty ? "trace" : result
    }
}
