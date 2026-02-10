import Foundation
import CryptoKit
import WhispCore

extension WhispCLI {
    static func loadManualBenchmarkCases(path: String) throws -> [ManualBenchmarkCase] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidArgument("manual test case path が空です")
        }
        guard FileManager.default.fileExists(atPath: trimmed) else {
            throw AppError.invalidArgument("manual test case file が見つかりません: \(trimmed)")
        }

        let content = try String(contentsOfFile: trimmed, encoding: .utf8)
        var results: [ManualBenchmarkCase] = []
        let decoder = JSONDecoder()

        for (index, rawLine) in content.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            guard let data = line.data(using: .utf8) else {
                throw AppError.invalidArgument("JSONLの読み込みに失敗しました(line=\(index + 1))")
            }
            do {
                let item = try decoder.decode(ManualBenchmarkCase.self, from: data)
                results.append(item)
            } catch {
                throw AppError.invalidArgument("JSONLのデコードに失敗しました(line=\(index + 1)): \(error.localizedDescription)")
            }
        }
        return results
    }

    static func prepareManualBenchmarkLogPaths(customDir: String?) throws -> ManualBenchmarkLogPaths {
        let basePath: String
        if let customDir {
            let trimmed = customDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw AppError.invalidArgument("--benchmark-log-dir が空です")
            }
            basePath = trimmed
        } else {
            let token = benchmarkTimestampToken()
            basePath = "/tmp/whisp-manualbench-\(token)"
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: basePath, isDirectory: true),
            withIntermediateDirectories: true
        )
        return ManualBenchmarkLogPaths(
            baseDir: basePath,
            caseRowsPath: URL(fileURLWithPath: basePath).appendingPathComponent("manual_case_rows.jsonl").path,
            summaryPath: URL(fileURLWithPath: basePath).appendingPathComponent("manual_summary.json").path
        )
    }

    static func benchmarkTimestampToken() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    static func openWriteHandle(path: String) throws -> FileHandle {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data())
        } else {
            try Data().write(to: url, options: .atomic)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw AppError.io("file open failed: \(path)")
        }
        return handle
    }

    static func appendJSONLine<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    static func writeJSONFile<T: Encodable>(_ value: T, path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    static func prepareComponentBenchmarkLogPaths(
        customDir: String?,
        defaultPrefix: String,
        rowsFilename: String,
        summaryFilename: String
    ) throws -> ComponentBenchmarkLogPaths {
        let basePath: String
        if let customDir {
            let trimmed = customDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw AppError.invalidArgument("--benchmark-log-dir が空です")
            }
            basePath = trimmed
        } else {
            basePath = "/tmp/\(defaultPrefix)-\(benchmarkTimestampToken())"
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: basePath, isDirectory: true),
            withIntermediateDirectories: true
        )
        return ComponentBenchmarkLogPaths(
            baseDir: basePath,
            rowsPath: URL(fileURLWithPath: basePath).appendingPathComponent(rowsFilename).path,
            summaryPath: URL(fileURLWithPath: basePath).appendingPathComponent(summaryFilename).path
        )
    }

    static func benchmarkCacheRootURL() -> URL {
        (try? WhispPaths().benchmarkCacheDirectory)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("whisp-benchmark-cache", isDirectory: true)
    }

    static func cacheFileURL(component: String, key: String) -> URL {
        benchmarkCacheRootURL()
            .appendingPathComponent(component, isDirectory: true)
            .appendingPathComponent("\(key).json", isDirectory: false)
    }

    static func loadCacheEntry<T: Decodable>(component: String, key: String) -> T? {
        let url = cacheFileURL(component: component, key: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func saveCacheEntry<T: Encodable>(component: String, key: String, value: T) throws {
        let url = cacheFileURL(component: component, key: key)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    static func sha256Hex(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(text: String) -> String {
        sha256Hex(data: Data(text.utf8))
    }

    static func canonicalContextString(_ context: ContextInfo?) -> String {
        guard let context else { return "{}" }
        let payload: [String: Any] = [
            "accessibilityText": context.accessibilityText ?? "",
            "windowText": context.windowText ?? "",
            "visionSummary": context.visionSummary ?? "",
            "visionTerms": context.visionTerms,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    static func inferImageMimeType(path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "webp":
            return "image/webp"
        default:
            return "image/jpeg"
        }
    }

    static func termSetScore(reference: [String], hypothesis: [String]) -> TermScore {
        let refSet = Set(reference.map(normalizedTerm))
        let hypSet = Set(hypothesis.map(normalizedTerm))
        if refSet.isEmpty, hypSet.isEmpty {
            return TermScore(precision: 1, recall: 1, f1: 1)
        }
        if hypSet.isEmpty {
            return TermScore(precision: 0, recall: 0, f1: 0)
        }
        let intersection = refSet.intersection(hypSet).count
        let precision = Double(intersection) / Double(max(1, hypSet.count))
        let recall = Double(intersection) / Double(max(1, refSet.count))
        let denom = precision + recall
        let f1 = denom > 0 ? (2 * precision * recall / denom) : 0
        return TermScore(precision: precision, recall: recall, f1: f1)
    }

    static func normalizedTerm(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
