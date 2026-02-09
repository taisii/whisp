import Foundation
import OSLog

public enum SystemLog {
    private static let subsystem = "com.taisii.whisp"
    private static let appLogger = Logger(subsystem: subsystem, category: "app")
    private static let audioLogger = Logger(subsystem: subsystem, category: "audio")
    private static let sttLogger = Logger(subsystem: subsystem, category: "stt")

    public static func app(_ event: String, fields: [String: String] = [:]) {
        write(logger: appLogger, event: event, fields: fields)
    }

    public static func audio(_ event: String, fields: [String: String] = [:]) {
        write(logger: audioLogger, event: event, fields: fields)
    }

    public static func stt(_ event: String, fields: [String: String] = [:]) {
        write(logger: sttLogger, event: event, fields: fields)
    }

    private static func write(logger: Logger, event: String, fields: [String: String]) {
        let body = fields
            .sorted(by: { $0.key < $1.key })
            .map { key, value in
                let safe = value.replacingOccurrences(of: " ", with: "_")
                return "\(key)=\(safe)"
            }
            .joined(separator: " ")
        let line = body.isEmpty ? event : "\(event) \(body)"
        logger.info("\(line, privacy: .public)")
    }
}
