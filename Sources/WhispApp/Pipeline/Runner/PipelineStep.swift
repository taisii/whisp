import Foundation

protocol PipelineStep {
    associatedtype Context
    func run(context: inout Context) async throws
}

struct AnyPipelineStep<Context>: PipelineStep {
    private let block: @Sendable (inout Context) async throws -> Void

    init(_ block: @escaping @Sendable (inout Context) async throws -> Void) {
        self.block = block
    }

    func run(context: inout Context) async throws {
        try await block(&context)
    }
}
