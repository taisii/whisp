import Foundation

public final class DebugCaptureStore: @unchecked Sendable {
    public static let shared = DebugCaptureStore()

    let lock = NSLock()
    let fileManager = FileManager.default
    let runsURL: URL
    let manualCasesURL: URL
    let manualCaseAssetsURL: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let paths = try? WhispPaths(environment: environment, allowTemporaryFallback: true)
        let debugDirectory = paths?.debugDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("whisp-debug", isDirectory: true)
        runsURL = paths?.runsDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("whisp-debug-runs", isDirectory: true)
        manualCasesURL = paths?.manualCasesFile
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("manual_test_cases.jsonl", isDirectory: false)
        manualCaseAssetsURL = debugDirectory.appendingPathComponent("manual_case_assets", isDirectory: true)
    }

    public var capturesDirectoryPath: String { runsURL.path }
    public var promptsDirectoryPath: String { runsURL.path }
    public var manualCasesPath: String { manualCasesURL.path }
    public var manualCaseAssetsPath: String { manualCaseAssetsURL.path }
}
