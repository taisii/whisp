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
    public static var directoryPath: String? {
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["WHISP_PROMPT_TRACE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty {
            return raw
        }

        guard let home = environment["HOME"], !home.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("whisp", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("prompts", isDirectory: true)
            .path
    }

    public static var isEnabled: Bool {
        directoryPath != nil
    }

    public static func dump(
        stage: String,
        model: String,
        appName: String?,
        context: ContextInfo?,
        prompt: String,
        extra: [String: String] = [:]
    ) {
        guard let directoryPath else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeStage = sanitizeFileToken(stage)
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let baseName = "\(timestamp.replacingOccurrences(of: ":", with: "-"))-\(safeStage)-\(id)"

        let dirURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
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
