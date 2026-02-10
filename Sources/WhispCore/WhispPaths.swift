import Foundation

public struct WhispPaths: Sendable {
    public let homeDirectory: URL
    public let baseDirectory: URL
    public let configFile: URL
    public let usageFile: URL
    public let debugDirectory: URL
    public let runsDirectory: URL
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
        manualCasesFile = debugDirectory.appendingPathComponent("manual_test_cases.jsonl", isDirectory: false)
        promptDefaultDirectory = runsDirectory
            .appendingPathComponent("_default", isDirectory: true)
            .appendingPathComponent("prompts", isDirectory: true)
        devLogFile = baseDirectory.appendingPathComponent("dev.log", isDirectory: false)
        benchmarkCacheDirectory = baseDirectory.appendingPathComponent("benchmark_cache", isDirectory: true)
    }
}
