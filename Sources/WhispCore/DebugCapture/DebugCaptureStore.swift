import Foundation

public final class DebugCaptureStore: @unchecked Sendable {
    public static let shared = DebugCaptureStore()

    let lock = NSLock()
    let fileManager = FileManager.default
    let runsURL: URL
    let manualCasesURL: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = environment["HOME"] ?? NSTemporaryDirectory()
        let baseURL = URL(fileURLWithPath: home)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("whisp", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
        runsURL = baseURL.appendingPathComponent("runs", isDirectory: true)
        manualCasesURL = baseURL.appendingPathComponent("manual_test_cases.jsonl", isDirectory: false)
    }

    public var capturesDirectoryPath: String { runsURL.path }
    public var promptsDirectoryPath: String { runsURL.path }
    public var manualCasesPath: String { manualCasesURL.path }
}
