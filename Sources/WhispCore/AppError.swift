import Foundation

public enum AppError: Error, Equatable {
    case io(String)
    case decode(String)
    case encode(String)
    case configDirMissing
    case invalidArgument(String)
}

extension AppError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .io(let message):
            return "io error: \(message)"
        case .decode(let message):
            return "decode error: \(message)"
        case .encode(let message):
            return "encode error: \(message)"
        case .configDirMissing:
            return "config directory not found"
        case .invalidArgument(let message):
            return message
        }
    }
}
