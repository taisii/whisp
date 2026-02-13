import Foundation

public final class BenchmarkCandidateStore: @unchecked Sendable {
    let lock = NSLock()
    let fileManager = FileManager.default
    let directoryURL: URL
    let fileURL: URL
    let initialSeedMarkerURL: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let paths = try? WhispPaths(environment: environment, allowTemporaryFallback: true)
        directoryURL = paths?.benchmarkDirectory
            .appendingPathComponent("candidates", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("whisp-benchmark-candidates", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("candidates.json", isDirectory: false)
        initialSeedMarkerURL = directoryURL.appendingPathComponent("initial_seed_done", isDirectory: false)
    }

    public var candidatesFilePath: String { fileURL.path }

    public func hasCompletedInitialSeed() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectoryExists()
        return fileManager.fileExists(atPath: initialSeedMarkerURL.path)
    }

    public func markInitialSeedCompleted() throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectoryExists()
        if !fileManager.fileExists(atPath: initialSeedMarkerURL.path) {
            try Data("done".utf8).write(to: initialSeedMarkerURL, options: [.atomic])
        }
    }

    public func listCandidates() throws -> [BenchmarkCandidate] {
        lock.lock()
        defer { lock.unlock() }
        return try loadCandidatesWithoutLock().sorted { $0.id < $1.id }
    }

    public func loadCandidate(id: String) throws -> BenchmarkCandidate? {
        lock.lock()
        defer { lock.unlock() }
        return try loadCandidatesWithoutLock().first { $0.id == id }
    }

    @discardableResult
    public func upsertCandidate(_ candidate: BenchmarkCandidate) throws -> BenchmarkCandidate {
        lock.lock()
        defer { lock.unlock() }

        var candidates = try loadCandidatesWithoutLock()
        if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
            candidates[index] = candidate
        } else {
            candidates.append(candidate)
        }
        try saveCandidatesWithoutLock(candidates)
        return candidate
    }

    public func deleteCandidate(id: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var candidates = try loadCandidatesWithoutLock()
        candidates.removeAll { $0.id == id }
        try saveCandidatesWithoutLock(candidates)
    }

    public func saveCandidates(_ candidates: [BenchmarkCandidate]) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveCandidatesWithoutLock(candidates)
    }

    func loadCandidatesWithoutLock() throws -> [BenchmarkCandidate] {
        try ensureDirectoryExists()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            return []
        }
        do {
            return try JSONDecoder().decode([BenchmarkCandidate].self, from: data)
        } catch {
            throw AppError.decode("failed to decode candidates.json: \(error.localizedDescription)")
        }
    }

    func saveCandidatesWithoutLock(_ candidates: [BenchmarkCandidate]) throws {
        let ids = candidates.map(\.id)
        let duplicates = Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys.sorted()
        if let duplicate = duplicates.first {
            throw AppError.invalidArgument("candidate_id が重複しています: \(duplicate)")
        }

        try ensureDirectoryExists()
        let sorted = candidates.sorted { $0.id < $1.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sorted)
        try data.write(to: fileURL, options: [.atomic])
    }

    func ensureDirectoryExists() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            try Data("[]".utf8).write(to: fileURL, options: [.atomic])
        }
    }
}
