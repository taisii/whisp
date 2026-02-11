import Foundation
import WhispCore

extension WhispCLI {
    static func loadContextInfo(path: String?) throws -> ContextInfo? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: trimmed))
        return try JSONDecoder().decode(ContextInfo.self, from: data)
    }

    static func defaultManualCasesPath() -> String {
        (try? WhispPaths().manualCasesFile.path)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("manual_test_cases.jsonl", isDirectory: false)
            .path
    }

    static func normalizedEvalText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func levenshteinDistance(_ left: [Character], _ right: [Character]) -> Int {
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let substitutionCost = left[i - 1] == right[j - 1] ? 0 : 1
                let deletion = previous[j] + 1
                let insertion = current[j - 1] + 1
                let substitution = previous[j - 1] + substitutionCost
                current[j] = min(deletion, insertion, substitution)
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }
    static func emitResult(_ text: String, mode: EmitMode) throws {
        switch mode {
        case .discard:
            return
        case .stdout:
            print("output: \(text)")
        case .pbcopy:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            if let data = text.data(using: .utf8) {
                pipe.fileHandleForWriting.write(data)
            }
            pipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw AppError.io("pbcopy failed")
            }
        }
    }

    static func dominantStage(sttAfterStopMs: Double, postMs: Double, outputMs: Double) -> String {
        var stage = "stt_after_stop"
        var maxValue = sttAfterStopMs
        if postMs > maxValue {
            stage = "post"
            maxValue = postMs
        }
        if outputMs > maxValue {
            stage = "output"
        }
        return stage
    }

    static func sampleText(_ text: String, limit: Int = 120) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else {
            return compact
        }
        return String(compact.prefix(limit)) + "..."
    }

    static func audioDurationSeconds(audio: AudioData) -> Double {
        let samples = Double(audio.pcmBytes.count) / Double(MemoryLayout<Int16>.size)
        return samples / Double(audio.sampleRate)
    }

    static func elapsedMs(since start: DispatchTime, to end: DispatchTime = .now()) -> Double {
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Double(nanos) / 1_000_000
    }

    static func msString(_ ms: Double) -> String {
        String(format: "%.1f", ms)
    }

    static func latencyDistribution(values: [Double]) -> LatencyDistributionLog? {
        let sanitized = values.filter { $0 >= 0 }.sorted()
        guard !sanitized.isEmpty else { return nil }
        let avg = sanitized.reduce(0, +) / Double(sanitized.count)
        return LatencyDistributionLog(
            avg: avg,
            p50: percentile(values: sanitized, percentile: 50),
            p95: percentile(values: sanitized, percentile: 95),
            p99: percentile(values: sanitized, percentile: 99)
        )
    }

    static func percentile(values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let bounded = max(0, min(100, percentile))
        if values.count == 1 {
            return values[0]
        }
        let rank = (bounded / 100.0) * Double(values.count - 1)
        let lowerIndex = Int(floor(rank))
        let upperIndex = Int(ceil(rank))
        if lowerIndex == upperIndex {
            return values[lowerIndex]
        }
        let weight = rank - Double(lowerIndex)
        return values[lowerIndex] * (1 - weight) + values[upperIndex] * weight
    }
}
