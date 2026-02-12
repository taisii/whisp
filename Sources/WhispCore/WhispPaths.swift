import Foundation

public struct WhispPaths: Sendable {
    public let homeDirectory: URL
    public let baseDirectory: URL
    public let configFile: URL
    public let usageFile: URL
    public let debugDirectory: URL
    public let runsDirectory: URL
    public let benchmarkDirectory: URL
    public let benchmarkRunsDirectory: URL
    public let benchmarkCandidatesDirectory: URL
    public let benchmarkIntegrityDirectory: URL
    public let statsDirectory: URL
    public let runtimeStatsFile: URL
    public let manualCasesFile: URL
    public let promptDefaultDirectory: URL
    public let devLogFile: URL
    public let benchmarkCacheDirectory: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowTemporaryFallback: Bool = false
    ) throws {
        let rawHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawHome, !rawHome.isEmpty {
            homeDirectory = URL(fileURLWithPath: rawHome, isDirectory: true)
        } else if allowTemporaryFallback {
            homeDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        } else {
            throw AppError.configDirMissing
        }

        baseDirectory = homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("whisp", isDirectory: true)

        configFile = baseDirectory.appendingPathComponent("config.json", isDirectory: false)
        usageFile = baseDirectory.appendingPathComponent("usage.json", isDirectory: false)
        debugDirectory = baseDirectory.appendingPathComponent("debug", isDirectory: true)
        runsDirectory = debugDirectory.appendingPathComponent("runs", isDirectory: true)
        benchmarkDirectory = debugDirectory.appendingPathComponent("benchmarks", isDirectory: true)
        benchmarkRunsDirectory = benchmarkDirectory.appendingPathComponent("runs", isDirectory: true)
        benchmarkCandidatesDirectory = benchmarkDirectory.appendingPathComponent("candidates", isDirectory: true)
        benchmarkIntegrityDirectory = benchmarkDirectory.appendingPathComponent("integrity", isDirectory: true)
        statsDirectory = debugDirectory.appendingPathComponent("stats", isDirectory: true)
        runtimeStatsFile = statsDirectory.appendingPathComponent("runtime_stats.json", isDirectory: false)
        manualCasesFile = debugDirectory.appendingPathComponent("manual_test_cases.jsonl", isDirectory: false)
        promptDefaultDirectory = runsDirectory
            .appendingPathComponent("_default", isDirectory: true)
            .appendingPathComponent("prompts", isDirectory: true)
        devLogFile = baseDirectory.appendingPathComponent("dev.log", isDirectory: false)
        benchmarkCacheDirectory = baseDirectory.appendingPathComponent("benchmark_cache", isDirectory: true)
    }

    public static func normalizeForStorage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let resolvedPath: String
        if trimmed.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            resolvedPath = home + "/" + trimmed.dropFirst(2)
        } else {
            resolvedPath = trimmed
        }
        return URL(fileURLWithPath: resolvedPath).standardizedFileURL.path
    }
}
