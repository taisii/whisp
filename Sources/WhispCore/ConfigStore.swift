import Foundation

public final class ConfigStore {
    public let path: URL

    public init(path: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let path {
            self.path = path
            return
        }
        self.path = try WhispPaths(environment: environment).configFile
    }

    public func load() throws -> Config {
        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            var config = try decoder.decode(Config.self, from: data)
            config.llmModel = LLMModelCatalog.resolveOrFallback(config.llmModel, for: .pipelineExecution)
            return config
        } catch {
            throw AppError.decode(error.localizedDescription)
        }
    }

    public func save(_ config: Config) throws {
        do {
            let dir = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: path)
        } catch {
            throw AppError.encode(error.localizedDescription)
        }
    }

    public func ensureExists(default config: Config) throws {
        if FileManager.default.fileExists(atPath: path.path) {
            return
        }
        try save(config)
    }
}
