import CryptoKit
import Foundation

public struct BenchmarkIntegrityScanCase: Codable, Equatable, Sendable {
    public let id: String
    public let audioFile: String?
    public let sttText: String?
    public let groundTruthText: String?
    public let transcriptGold: String?
    public let transcriptSilver: String?

    public init(
        id: String,
        audioFile: String?,
        sttText: String?,
        groundTruthText: String?,
        transcriptGold: String?,
        transcriptSilver: String?
    ) {
        self.id = id
        self.audioFile = audioFile
        self.sttText = sttText
        self.groundTruthText = groundTruthText
        self.transcriptGold = transcriptGold
        self.transcriptSilver = transcriptSilver
    }
}

public struct BenchmarkIntegrityCaseFingerprint: Codable, Equatable, Sendable {
    public let caseID: String
    public let value: String

    public init(caseID: String, value: String) {
        self.caseID = caseID
        self.value = value
    }
}

public struct BenchmarkIntegrityAutoScanState: Codable, Equatable, Sendable {
    public let sourcePath: String
    public let fingerprintsByCaseID: [String: String]
    public let lastScannedAt: String

    public init(
        sourcePath: String,
        fingerprintsByCaseID: [String: String],
        lastScannedAt: String
    ) {
        self.sourcePath = sourcePath
        self.fingerprintsByCaseID = fingerprintsByCaseID
        self.lastScannedAt = lastScannedAt
    }
}

public enum BenchmarkIntegrityScanner {
    public static func fingerprint(case item: BenchmarkIntegrityScanCase) -> BenchmarkIntegrityCaseFingerprint {
        let normalized = [
            item.id,
            normalize(item.audioFile),
            normalize(item.sttText),
            normalize(item.groundTruthText),
            normalize(item.transcriptGold),
            normalize(item.transcriptSilver),
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return BenchmarkIntegrityCaseFingerprint(caseID: item.id, value: digest)
    }

    public static func scanIssues(
        task: BenchmarkKind,
        cases: [BenchmarkIntegrityScanCase],
        sourcePath: String,
        detectedAt: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [BenchmarkIntegrityIssue] {
        guard task == .stt || task == .generation else {
            return []
        }

        var issues: [BenchmarkIntegrityIssue] = []
        for item in cases {
            switch task {
            case .stt:
                let hasReference = hasSTTReference(item: item)
                if !hasReference {
                    issues.append(makeIssue(
                        caseID: item.id,
                        task: .stt,
                        issueType: "missing_reference",
                        missingFields: ["ground_truth_text|labels.transcript_gold|labels.transcript_silver|stt_text"],
                        sourcePath: sourcePath,
                        detectedAt: detectedAt
                    ))
                }
                let audioPath = normalize(item.audioFile)
                if audioPath.isEmpty || !fileExists(audioPath) {
                    issues.append(makeIssue(
                        caseID: item.id,
                        task: .stt,
                        issueType: "missing_audio_file",
                        missingFields: ["audio_file"],
                        sourcePath: sourcePath,
                        detectedAt: detectedAt
                    ))
                }
            case .generation:
                if normalize(item.sttText).isEmpty {
                    issues.append(makeIssue(
                        caseID: item.id,
                        task: .generation,
                        issueType: "missing_stt_text",
                        missingFields: ["stt_text"],
                        sourcePath: sourcePath,
                        detectedAt: detectedAt
                    ))
                }
                if !hasGenerationReference(item: item) {
                    issues.append(makeIssue(
                        caseID: item.id,
                        task: .generation,
                        issueType: "missing_reference",
                        missingFields: ["ground_truth_text|labels.transcript_gold|labels.transcript_silver"],
                        sourcePath: sourcePath,
                        detectedAt: detectedAt
                    ))
                }
            case .vision:
                break
            }
        }
        return dedupeIssues(issues)
    }

    public static func scanIssuesForDefaultTasks(
        cases: [BenchmarkIntegrityScanCase],
        sourcePath: String,
        detectedAt: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [BenchmarkKind: [BenchmarkIntegrityIssue]] {
        let sttIssues = scanIssues(
            task: .stt,
            cases: cases,
            sourcePath: sourcePath,
            detectedAt: detectedAt,
            fileExists: fileExists
        )
        let generationIssues = scanIssues(
            task: .generation,
            cases: cases,
            sourcePath: sourcePath,
            detectedAt: detectedAt,
            fileExists: fileExists
        )
        return [
            .stt: sttIssues,
            .generation: generationIssues,
        ]
    }

    private static func normalize(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasSTTReference(item: BenchmarkIntegrityScanCase) -> Bool {
        !normalize(item.transcriptGold).isEmpty ||
            !normalize(item.sttText).isEmpty ||
            !normalize(item.transcriptSilver).isEmpty ||
            !normalize(item.groundTruthText).isEmpty
    }

    private static func hasGenerationReference(item: BenchmarkIntegrityScanCase) -> Bool {
        !normalize(item.groundTruthText).isEmpty ||
            !normalize(item.transcriptGold).isEmpty ||
            !normalize(item.transcriptSilver).isEmpty
    }

    private static func dedupeIssues(_ issues: [BenchmarkIntegrityIssue]) -> [BenchmarkIntegrityIssue] {
        let grouped = Dictionary(grouping: issues, by: \.id)
        return grouped.values
            .compactMap { $0.first }
            .sorted { lhs, rhs in
                if lhs.caseID != rhs.caseID {
                    return lhs.caseID < rhs.caseID
                }
                if lhs.task.rawValue != rhs.task.rawValue {
                    return lhs.task.rawValue < rhs.task.rawValue
                }
                return lhs.issueType < rhs.issueType
            }
    }

    private static func makeIssue(
        caseID: String,
        task: BenchmarkKind,
        issueType: String,
        missingFields: [String],
        sourcePath: String,
        detectedAt: String
    ) -> BenchmarkIntegrityIssue {
        let key = "\(task.rawValue)|\(sourcePath)|\(caseID)|\(issueType)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return BenchmarkIntegrityIssue(
            id: digest,
            caseID: caseID,
            task: task,
            issueType: issueType,
            missingFields: missingFields,
            sourcePath: sourcePath,
            excluded: false,
            detectedAt: detectedAt
        )
    }
}
