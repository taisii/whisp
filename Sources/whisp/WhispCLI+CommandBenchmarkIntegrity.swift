import Foundation
import WhispCore

extension WhispCLI {
    static func runBenchmarkIntegrityScan(options: BenchmarkIntegrityScanOptions) throws {
        guard options.task == .stt || options.task == .generation else {
            throw AppError.invalidArgument("--benchmark-scan-integrity は stt/generation のみ対応です")
        }

        let casesPath = URL(fileURLWithPath: options.casesPath).standardizedFileURL.path
        let cases = try loadManualBenchmarkCases(path: casesPath)
        let detectedAt = isoNow()
        var issues: [BenchmarkIntegrityIssue] = []

        for item in cases {
            switch options.task {
            case .stt:
                if item.resolvedSTTReferenceTranscript() == nil {
                    issues.append(makeIntegrityIssue(
                        caseID: item.id,
                        task: .stt,
                        issueType: "missing_reference",
                        missingFields: ["ground_truth_text|labels.transcript_gold|labels.transcript_silver|stt_text"],
                        sourcePath: casesPath,
                        detectedAt: detectedAt
                    ))
                }
                if item.audioFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !FileManager.default.fileExists(atPath: item.audioFile) {
                    issues.append(makeIntegrityIssue(
                        caseID: item.id,
                        task: .stt,
                        issueType: "missing_audio_file",
                        missingFields: ["audio_file"],
                        sourcePath: casesPath,
                        detectedAt: detectedAt
                    ))
                }
            case .generation:
                let stt = (item.sttText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if stt.isEmpty {
                    issues.append(makeIntegrityIssue(
                        caseID: item.id,
                        task: .generation,
                        issueType: "missing_stt_text",
                        missingFields: ["stt_text"],
                        sourcePath: casesPath,
                        detectedAt: detectedAt
                    ))
                }
                if item.resolvedGenerationReferenceText() == nil {
                    issues.append(makeIntegrityIssue(
                        caseID: item.id,
                        task: .generation,
                        issueType: "missing_reference",
                        missingFields: ["ground_truth_text|labels.transcript_gold|labels.transcript_silver"],
                        sourcePath: casesPath,
                        detectedAt: detectedAt
                    ))
                }
            case .vision:
                break
            }
        }

        let deduped = Dictionary(grouping: issues, by: { $0.id }).compactMap { $0.value.first }
        let store = BenchmarkIntegrityStore()
        try store.saveIssues(task: options.task, issues: deduped)
        let saved = try store.loadIssues(task: options.task)

        print("mode: benchmark_integrity_scan")
        print("task: \(options.task.rawValue)")
        print("cases: \(casesPath)")
        print("cases_total: \(cases.count)")
        print("issues_total: \(saved.count)")
        print("issues_excluded: \(saved.filter { $0.excluded }.count)")
        print("issues_file: \(store.issuesFilePath(task: options.task))")
        for issue in saved {
            print("\(issue.caseID)\t\(issue.issueType)\texcluded=\(issue.excluded)\tmissing=\(issue.missingFields.joined(separator: ","))")
        }
    }

    private static func makeIntegrityIssue(
        caseID: String,
        task: BenchmarkKind,
        issueType: String,
        missingFields: [String],
        sourcePath: String,
        detectedAt: String
    ) -> BenchmarkIntegrityIssue {
        let id = sha256Hex(text: "\(task.rawValue)|\(sourcePath)|\(caseID)|\(issueType)")
        return BenchmarkIntegrityIssue(
            id: id,
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
