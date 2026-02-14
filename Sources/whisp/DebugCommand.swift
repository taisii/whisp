import ArgumentParser
import Foundation

struct DebugCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Read-only diagnostics for benchmark/runtime state",
        subcommands: [
            DebugSelfCheckCommand.self,
            DebugBenchmarkStatusCommand.self,
            DebugBenchmarkIntegrityCommand.self,
        ]
    )
}
