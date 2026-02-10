import Foundation

enum TaskReadiness {
    static func awaitIfReady<T: Sendable>(
        task: Task<T, Never>,
        graceNanoseconds: UInt64 = 1_000_000
    ) async -> (ready: Bool, value: T?) {
        await withTaskGroup(of: (Bool, T?).self, returning: (Bool, T?).self) { group in
            group.addTask {
                (true, await task.value)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: graceNanoseconds)
                return (false, nil)
            }
            let first = await group.next() ?? (false, nil)
            group.cancelAll()
            return first
        }
    }
}
