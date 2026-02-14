#!/usr/bin/env swift
import Foundation

enum JSONValue: Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
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
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .object(obj):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in obj {
                try container.encode(value, forKey: DynamicCodingKey.make(key))
            }
        case let .array(arr):
            var container = encoder.unkeyedContainer()
            for value in arr {
                try container.encode(value)
            }
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }

    static func make(_ key: String) -> DynamicCodingKey {
        guard let value = DynamicCodingKey(stringValue: key) else {
            preconditionFailure("invalid dynamic coding key: \(key)")
        }
        return value
    }
}

func canonicalize(_ first: String, _ second: String) -> (left: String, right: String) {
    if first <= second {
        return (first, second)
    }
    return (second, first)
}

func updateManifestJSON(_ root: JSONValue) -> (updated: JSONValue, changed: Bool) {
    guard var object = root.objectValue else {
        return (root, false)
    }
    guard var options = object["options"]?.objectValue,
          options["kind"]?.stringValue == "generation_pairwise",
          var pairwise = options["generationPairwise"]?.objectValue
    else {
        return (root, false)
    }

    let candidateA = pairwise["pairCandidateAID"]?.stringValue ?? pairwise["pair_candidate_a_id"]?.stringValue
    let candidateB = pairwise["pairCandidateBID"]?.stringValue ?? pairwise["pair_candidate_b_id"]?.stringValue
    guard let candidateA, let candidateB, !candidateA.isEmpty, !candidateB.isEmpty else {
        return (root, false)
    }

    let canonical = canonicalize(candidateA, candidateB)
    let canonicalObject: JSONValue = .object([
        "leftCandidateID": .string(canonical.left),
        "rightCandidateID": .string(canonical.right),
    ])
    let executionObject: JSONValue = .object([
        "firstCandidateID": .string(candidateA),
        "secondCandidateID": .string(candidateB),
    ])

    pairwise["pairCanonicalID"] = canonicalObject
    pairwise["pairExecutionOrder"] = executionObject
    options["generationPairwise"] = .object(pairwise)
    object["options"] = .object(options)

    if var benchmarkKey = object["benchmarkKey"]?.objectValue {
        benchmarkKey["candidateID"] = .string("pair:\(canonical.left)__vs__\(canonical.right)")
        object["benchmarkKey"] = .object(benchmarkKey)
    }

    return (.object(object), true)
}

let defaultRoot = ("~/.config/whisp/debug/benchmarks/runs" as NSString).expandingTildeInPath
let runsRoot = CommandLine.arguments.count >= 2 ? CommandLine.arguments[1] : defaultRoot
let fileManager = FileManager.default

guard fileManager.fileExists(atPath: runsRoot) else {
    fputs("runs directory not found: \(runsRoot)\n", stderr)
    exit(1)
}

let runDirectories = (try? fileManager.contentsOfDirectory(atPath: runsRoot)) ?? []
var updatedCount = 0
var scannedCount = 0

for name in runDirectories {
    let manifestPath = (runsRoot as NSString).appendingPathComponent(name).appending("/manifest.json")
    guard fileManager.fileExists(atPath: manifestPath) else {
        continue
    }
    scannedCount += 1
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let decoder = JSONDecoder()
        let root = try decoder.decode(JSONValue.self, from: data)
        let result = updateManifestJSON(root)
        guard result.changed else {
            continue
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let updatedData = try encoder.encode(result.updated)
        try updatedData.write(to: URL(fileURLWithPath: manifestPath), options: [.atomic])
        updatedCount += 1
    } catch {
        fputs("skip (decode/write error): \(manifestPath) :: \(error.localizedDescription)\n", stderr)
    }
}

print("scanned_manifests: \(scannedCount)")
print("updated_manifests: \(updatedCount)")
