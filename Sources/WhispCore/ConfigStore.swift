import Foundation

public final class ConfigStore {
    public let path: URL

    public init(path: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let path {
            self.path = path
            return
        }
        guard let home = environment["HOME"] else {
            throw AppError.configDirMissing
        }
        self.path = URL(fileURLWithPath: home)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("whisp", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    public func load() throws -> Config {
        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            return try decoder.decode(Config.self, from: data)
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

    public func loadOrCreate() throws -> Config {
        do {
            return try load()
        } catch {
            let config = Config()
            try save(config)
            return config
        }
    }
}
