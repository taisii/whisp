import Foundation

private actor DevLogWriter {
    private let path: URL?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let home = environment["HOME"] else {
            path = nil
            return
        }
        path = URL(fileURLWithPath: home)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("whisp", isDirectory: true)
            .appendingPathComponent("dev.log", isDirectory: false)
    }

    func append(_ line: String) {
        guard let path else { return }
        do {
            let dir = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path.path) {
                try Data().write(to: path)
            }

            guard let handle = try? FileHandle(forWritingTo: path) else {
                return
            }
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = (line + "\n").data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            // ignore log write failures in app flow
        }
    }
}

public enum DevLog {
    private static let writer = DevLogWriter()

    public static var isEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment["WHISP_DEV_LOG"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    public static var filePath: String? {
        guard let home = ProcessInfo.processInfo.environment["HOME"] else {
            return nil
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("whisp", isDirectory: true)
            .appendingPathComponent("dev.log", isDirectory: false)
            .path
    }

    public static func info(_ event: String, fields: [String: String] = [:]) {
        guard isEnabled else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let kv = fields
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: " ", with: "_"))" }
            .joined(separator: " ")
        let line: String
        if kv.isEmpty {
            line = "[dev][\(timestamp)] \(event)"
        } else {
            line = "[dev][\(timestamp)] \(event) \(kv)"
        }

        print(line)
        Task {
            await writer.append(line)
        }
    }
}
