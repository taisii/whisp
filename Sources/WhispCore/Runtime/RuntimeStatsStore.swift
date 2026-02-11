import Foundation

public enum RuntimeStatsOutcome: String, Codable, Sendable {
    case completed
    case skipped
    case failed
}

public enum RuntimeStatsStage: String, Codable, CaseIterable, Sendable {
    case stt
    case post
    case vision
    case directInput = "direct_input"
    case unknown
}

public struct RuntimeStatsEntry: Sendable {
    public let recordedAt: Date
    public let outcome: RuntimeStatsOutcome
    public let sttMs: Double?
    public let postMs: Double?
    public let visionMs: Double?
    public let directInputMs: Double?
    public let totalAfterStopMs: Double?

    public init(
        recordedAt: Date,
        outcome: RuntimeStatsOutcome,
        sttMs: Double? = nil,
        postMs: Double? = nil,
        visionMs: Double? = nil,
        directInputMs: Double? = nil,
        totalAfterStopMs: Double? = nil
    ) {
        self.recordedAt = recordedAt
        self.outcome = outcome
        self.sttMs = sttMs
        self.postMs = postMs
        self.visionMs = visionMs
        self.directInputMs = directInputMs
        self.totalAfterStopMs = totalAfterStopMs
    }
}

public enum RuntimeStatsWindow: String, Codable, CaseIterable, Sendable {
    case last24Hours = "24h"
    case last7Days = "7d"
    case last30Days = "30d"
    case all = "all"
}

public struct RuntimeStatsWindowSummary: Codable, Equatable, Sendable {
    public let totalRuns: Int
    public let completedRuns: Int
    public let skippedRuns: Int
    public let failedRuns: Int
    public let avgSttMs: Double?
    public let avgPostMs: Double?
    public let avgVisionMs: Double?
    public let avgDirectInputMs: Double?
    public let avgTotalAfterStopMs: Double?
    public let dominantStage: RuntimeStatsStage?

    public init(
        totalRuns: Int,
        completedRuns: Int,
        skippedRuns: Int,
        failedRuns: Int,
        avgSttMs: Double?,
        avgPostMs: Double?,
        avgVisionMs: Double?,
        avgDirectInputMs: Double?,
        avgTotalAfterStopMs: Double?,
        dominantStage: RuntimeStatsStage?
    ) {
        self.totalRuns = totalRuns
        self.completedRuns = completedRuns
        self.skippedRuns = skippedRuns
        self.failedRuns = failedRuns
        self.avgSttMs = avgSttMs
        self.avgPostMs = avgPostMs
        self.avgVisionMs = avgVisionMs
        self.avgDirectInputMs = avgDirectInputMs
        self.avgTotalAfterStopMs = avgTotalAfterStopMs
        self.dominantStage = dominantStage
    }
}

public struct RuntimeStatsSnapshot: Codable, Equatable, Sendable {
    public let updatedAt: String
    public let last24Hours: RuntimeStatsWindowSummary
    public let last7Days: RuntimeStatsWindowSummary
    public let last30Days: RuntimeStatsWindowSummary
    public let all: RuntimeStatsWindowSummary

    public init(
        updatedAt: String,
        last24Hours: RuntimeStatsWindowSummary,
        last7Days: RuntimeStatsWindowSummary,
        last30Days: RuntimeStatsWindowSummary,
        all: RuntimeStatsWindowSummary
    ) {
        self.updatedAt = updatedAt
        self.last24Hours = last24Hours
        self.last7Days = last7Days
        self.last30Days = last30Days
        self.all = all
    }

    public func summary(for window: RuntimeStatsWindow) -> RuntimeStatsWindowSummary {
        switch window {
        case .last24Hours:
            return last24Hours
        case .last7Days:
            return last7Days
        case .last30Days:
            return last30Days
        case .all:
            return all
        }
    }
}

private struct RuntimeStatsAggregate: Codable, Sendable {
    var totalRuns: Int
    var completedRuns: Int
    var skippedRuns: Int
    var failedRuns: Int
    var sttSumMs: Double
    var sttCount: Int
    var postSumMs: Double
    var postCount: Int
    var visionSumMs: Double
    var visionCount: Int
    var directInputSumMs: Double
    var directInputCount: Int
    var totalAfterStopSumMs: Double
    var totalAfterStopCount: Int
    var dominantStageCounts: [String: Int]

    init(
        totalRuns: Int = 0,
        completedRuns: Int = 0,
        skippedRuns: Int = 0,
        failedRuns: Int = 0,
        sttSumMs: Double = 0,
        sttCount: Int = 0,
        postSumMs: Double = 0,
        postCount: Int = 0,
        visionSumMs: Double = 0,
        visionCount: Int = 0,
        directInputSumMs: Double = 0,
        directInputCount: Int = 0,
        totalAfterStopSumMs: Double = 0,
        totalAfterStopCount: Int = 0,
        dominantStageCounts: [String: Int] = [:]
    ) {
        self.totalRuns = totalRuns
        self.completedRuns = completedRuns
        self.skippedRuns = skippedRuns
        self.failedRuns = failedRuns
        self.sttSumMs = sttSumMs
        self.sttCount = sttCount
        self.postSumMs = postSumMs
        self.postCount = postCount
        self.visionSumMs = visionSumMs
        self.visionCount = visionCount
        self.directInputSumMs = directInputSumMs
        self.directInputCount = directInputCount
        self.totalAfterStopSumMs = totalAfterStopSumMs
        self.totalAfterStopCount = totalAfterStopCount
        self.dominantStageCounts = dominantStageCounts
    }

    mutating func apply(entry: RuntimeStatsEntry) {
        totalRuns += 1
        switch entry.outcome {
        case .completed:
            completedRuns += 1
        case .skipped:
            skippedRuns += 1
        case .failed:
            failedRuns += 1
        }

        if let sttMs = positiveValue(entry.sttMs) {
            sttSumMs += sttMs
            sttCount += 1
        }
        if let postMs = positiveValue(entry.postMs) {
            postSumMs += postMs
            postCount += 1
        }
        if let visionMs = positiveValue(entry.visionMs) {
            visionSumMs += visionMs
            visionCount += 1
        }
        if let directInputMs = positiveValue(entry.directInputMs) {
            directInputSumMs += directInputMs
            directInputCount += 1
        }
        if let totalAfterStopMs = positiveValue(entry.totalAfterStopMs) {
            totalAfterStopSumMs += totalAfterStopMs
            totalAfterStopCount += 1
        }

        let dominant = RuntimeStatsAggregate.dominantStage(
            sttMs: entry.sttMs,
            postMs: entry.postMs,
            visionMs: entry.visionMs,
            directInputMs: entry.directInputMs
        ) ?? .unknown
        dominantStageCounts[dominant.rawValue, default: 0] += 1
    }

    mutating func merge(_ other: RuntimeStatsAggregate) {
        totalRuns += other.totalRuns
        completedRuns += other.completedRuns
        skippedRuns += other.skippedRuns
        failedRuns += other.failedRuns
        sttSumMs += other.sttSumMs
        sttCount += other.sttCount
        postSumMs += other.postSumMs
        postCount += other.postCount
        visionSumMs += other.visionSumMs
        visionCount += other.visionCount
        directInputSumMs += other.directInputSumMs
        directInputCount += other.directInputCount
        totalAfterStopSumMs += other.totalAfterStopSumMs
        totalAfterStopCount += other.totalAfterStopCount
        for (key, value) in other.dominantStageCounts {
            dominantStageCounts[key, default: 0] += value
        }
    }

    func toWindowSummary() -> RuntimeStatsWindowSummary {
        RuntimeStatsWindowSummary(
            totalRuns: totalRuns,
            completedRuns: completedRuns,
            skippedRuns: skippedRuns,
            failedRuns: failedRuns,
            avgSttMs: average(sum: sttSumMs, count: sttCount),
            avgPostMs: average(sum: postSumMs, count: postCount),
            avgVisionMs: average(sum: visionSumMs, count: visionCount),
            avgDirectInputMs: average(sum: directInputSumMs, count: directInputCount),
            avgTotalAfterStopMs: average(sum: totalAfterStopSumMs, count: totalAfterStopCount),
            dominantStage: dominantStageFromCounts(dominantStageCounts)
        )
    }

    private func average(sum: Double, count: Int) -> Double? {
        guard count > 0 else { return nil }
        return sum / Double(count)
    }

    private func dominantStageFromCounts(_ counts: [String: Int]) -> RuntimeStatsStage? {
        let ordered = RuntimeStatsStage.allCases
        var winner: RuntimeStatsStage?
        var winnerCount = 0
        for stage in ordered {
            let value = counts[stage.rawValue] ?? 0
            if value > winnerCount {
                winner = stage
                winnerCount = value
            }
        }
        return winnerCount > 0 ? winner : nil
    }

    private static func dominantStage(
        sttMs: Double?,
        postMs: Double?,
        visionMs: Double?,
        directInputMs: Double?
    ) -> RuntimeStatsStage? {
        let pairs: [(RuntimeStatsStage, Double)] = [
            (.stt, sttMs ?? -1),
            (.post, postMs ?? -1),
            (.vision, visionMs ?? -1),
            (.directInput, directInputMs ?? -1),
        ]
        guard let maxPair = pairs.max(by: { $0.1 < $1.1 }), maxPair.1 >= 0 else {
            return nil
        }
        return maxPair.0
    }

    private func positiveValue(_ value: Double?) -> Double? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}

private struct RuntimeStatsBucket: Codable, Sendable {
    var hourStartMs: Int64
    var aggregate: RuntimeStatsAggregate
}

private struct RuntimeStatsFile: Codable, Sendable {
    var schemaVersion: Int
    var updatedAt: String
    var total: RuntimeStatsAggregate
    var buckets: [RuntimeStatsBucket]

    init(
        schemaVersion: Int = 1,
        updatedAt: String,
        total: RuntimeStatsAggregate = RuntimeStatsAggregate(),
        buckets: [RuntimeStatsBucket] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.total = total
        self.buckets = buckets
    }
}

public final class RuntimeStatsStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let nowProvider: () -> Date
    private let retentionHours = 24 * 45
    private var stats: RuntimeStatsFile
    public let path: URL

    public init(
        path: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = Date.init
    ) throws {
        if let path {
            self.path = path
        } else {
            self.path = try WhispPaths(environment: environment, allowTemporaryFallback: true).runtimeStatsFile
        }
        nowProvider = now

        if fileManager.fileExists(atPath: self.path.path) {
            let data = try Data(contentsOf: self.path)
            stats = try JSONDecoder().decode(RuntimeStatsFile.self, from: data)
        } else {
            stats = RuntimeStatsFile(updatedAt: Self.isoString(now()))
        }
    }

    public var filePath: String {
        path.path
    }

    public func record(entry: RuntimeStatsEntry) throws {
        lock.lock()
        defer { lock.unlock() }

        let currentNow = nowProvider()
        pruneOldBuckets(reference: currentNow)

        let hourKey = hourStartMs(entry.recordedAt)
        if let index = stats.buckets.firstIndex(where: { $0.hourStartMs == hourKey }) {
            stats.buckets[index].aggregate.apply(entry: entry)
        } else {
            var aggregate = RuntimeStatsAggregate()
            aggregate.apply(entry: entry)
            stats.buckets.append(RuntimeStatsBucket(hourStartMs: hourKey, aggregate: aggregate))
        }
        stats.total.apply(entry: entry)
        stats.updatedAt = Self.isoString(currentNow)
        try saveLocked()
    }

    public func snapshot(now: Date? = nil) -> RuntimeStatsSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let reference = now ?? nowProvider()
        let all = stats.total.toWindowSummary()
        let summary24h = aggregate(for: .last24Hours, reference: reference).toWindowSummary()
        let summary7d = aggregate(for: .last7Days, reference: reference).toWindowSummary()
        let summary30d = aggregate(for: .last30Days, reference: reference).toWindowSummary()
        return RuntimeStatsSnapshot(
            updatedAt: stats.updatedAt,
            last24Hours: summary24h,
            last7Days: summary7d,
            last30Days: summary30d,
            all: all
        )
    }

    private func aggregate(for window: RuntimeStatsWindow, reference: Date) -> RuntimeStatsAggregate {
        guard let cutoff = cutoffDate(for: window, reference: reference) else {
            return stats.total
        }
        let cutoffHour = hourStartMs(cutoff)
        var aggregate = RuntimeStatsAggregate()
        for bucket in stats.buckets where bucket.hourStartMs >= cutoffHour {
            aggregate.merge(bucket.aggregate)
        }
        return aggregate
    }

    private func cutoffDate(for window: RuntimeStatsWindow, reference: Date) -> Date? {
        switch window {
        case .last24Hours:
            return reference.addingTimeInterval(-24 * 3600)
        case .last7Days:
            return reference.addingTimeInterval(-7 * 24 * 3600)
        case .last30Days:
            return reference.addingTimeInterval(-30 * 24 * 3600)
        case .all:
            return nil
        }
    }

    private func pruneOldBuckets(reference: Date) {
        let cutoff = reference.addingTimeInterval(TimeInterval(-retentionHours * 3600))
        let cutoffHour = hourStartMs(cutoff)
        stats.buckets = stats.buckets
            .filter { $0.hourStartMs >= cutoffHour }
            .sorted { $0.hourStartMs < $1.hourStartMs }
    }

    private func hourStartMs(_ date: Date) -> Int64 {
        let timestampMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let hourMs = Int64(3600 * 1000)
        return (timestampMs / hourMs) * hourMs
    }

    private func saveLocked() throws {
        let directory = path.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stats)
        try data.write(to: path, options: [.atomic])
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
