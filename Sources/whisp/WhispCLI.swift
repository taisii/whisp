import ArgumentParser
import Foundation
import WhispCore

@main
struct WhispCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whisp",
        abstract: "Whisp diagnostics CLI",
        subcommands: [DebugCommand.self]
    )
}

enum CLIOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case text
    case json
}

enum CLIBenchmarkTask: String, CaseIterable, ExpressibleByArgument {
    case stt
    case generation

    var kind: BenchmarkKind {
        switch self {
        case .stt:
            return .stt
        case .generation:
            return .generation
        }
    }
}

func writeCLIJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw AppError.encode("failed to encode JSON output")
    }
    print(json)
}
