import Foundation

public struct PromptTraceRecord: Codable, Sendable {
    public let timestamp: String
    public let stage: String
    public let model: String
    public let appName: String?
    public let context: ContextInfo?
    public let promptChars: Int
    public let promptFile: String
    public let extra: [String: String]

    public init(
        timestamp: String,
        stage: String,
        model: String,
        appName: String?,
        context: ContextInfo?,
        promptChars: Int,
        promptFile: String,
        extra: [String: String]
    ) {
        self.timestamp = timestamp
        self.stage = stage
        self.model = model
        self.appName = appName
        self.context = context
        self.promptChars = promptChars
        self.promptFile = promptFile
        self.extra = extra
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

        let home = (environment["HOME"] ?? NSTemporaryDirectory())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = home.isEmpty ? NSTemporaryDirectory() : home
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("whisp", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent("_default", isDirectory: true)
            .appendingPathComponent("prompts", isDirectory: true)
            .path
    }

    public static func dump(
        stage: String,
        model: String,
        appName: String?,
        context: ContextInfo?,
        prompt: String,
        extra: [String: String] = [:]
    ) {
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
        let baseName = "\(timestamp.replacingOccurrences(of: ":", with: "-"))-\(safeStage)-\(id)"

        let dirURL = URL(fileURLWithPath: targetDirectoryPath, isDirectory: true)
        let promptFile = "\(baseName).prompt.txt"
        let promptURL = dirURL.appendingPathComponent(promptFile, isDirectory: false)
        let metaURL = dirURL.appendingPathComponent("\(baseName).meta.json", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try prompt.write(to: promptURL, atomically: true, encoding: .utf8)

            let record = PromptTraceRecord(
                timestamp: timestamp,
                stage: stage,
                model: model,
                appName: appName,
                context: context,
                promptChars: prompt.count,
                promptFile: promptFile,
                extra: extra
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: metaURL, options: [.atomic])
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
