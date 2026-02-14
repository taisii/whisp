import ArgumentParser
import Foundation
import WhispCore

struct DebugSelfCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-check",
        abstract: "Run basic local validation"
    )

    mutating func run() async throws {
        let ok = !isEmptySTT("テスト")
        if ok {
            print("ok")
            return
        }
        throw AppError.invalidArgument("self-check failed")
    }
}
