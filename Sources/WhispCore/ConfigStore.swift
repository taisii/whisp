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
            config.shortcut = migratedShortcutString(config.shortcut)
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
            let data = try mergedConfigData(config)
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

    private func mergedConfigData(_ config: Config) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let replacementData = try encoder.encode(config)
        let replacementObject = try JSONDecoder().decode(JSONValue.self, from: replacementData)

        guard FileManager.default.fileExists(atPath: path.path) else {
            return replacementData
        }

        guard let existingData = try? Data(contentsOf: path),
              let existingObject = try? JSONDecoder().decode(JSONValue.self, from: existingData)
        else {
            return replacementData
        }

        let mergedObject = existingObject.merging(replacementObject)
        return try encoder.encode(mergedObject)
    }
}

private enum JSONValue: Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: JSONCodingKey.self) {
            var object: [String: JSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            while !container.isAtEnd {
                array.append(try container.decode(JSONValue.self))
            }
            self = .array(array)
            return
        }

        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let object):
            var container = encoder.container(keyedBy: JSONCodingKey.self)
            for (key, value) in object {
                try container.encode(value, forKey: .key(key))
            }
        case .array(let array):
            var container = encoder.unkeyedContainer()
            for value in array {
                try container.encode(value)
            }
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    func merging(_ replacement: JSONValue) -> JSONValue {
        switch (self, replacement) {
        case let (.object(existing), .object(newValues)):
            var merged = existing
            for (key, newValue) in newValues {
                if let existingValue = merged[key] {
                    merged[key] = existingValue.merging(newValue)
                } else {
                    merged[key] = newValue
                }
            }
            return .object(merged)
        default:
            return replacement
        }
    }
}

private struct JSONCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    private init(_ stringValue: String, intValue: Int? = nil) {
        self.stringValue = stringValue
        self.intValue = intValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.init(String(intValue), intValue: intValue)
    }

    static func key(_ stringValue: String) -> JSONCodingKey {
        JSONCodingKey(stringValue)
    }
}
