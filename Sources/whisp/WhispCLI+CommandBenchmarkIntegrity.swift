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
        let scanCases = cases.map { item in
            BenchmarkIntegrityScanCase(
                id: item.id,
                audioFile: item.audioFile,
                sttText: item.sttText,
                groundTruthText: item.groundTruthText,
                transcriptGold: item.labels?.transcriptGold,
                transcriptSilver: item.labels?.transcriptSilver
            )
        }
        let scanned = BenchmarkIntegrityScanner.scanIssues(
            task: options.task,
            cases: scanCases,
            sourcePath: casesPath,
            detectedAt: detectedAt
        )
        let store = BenchmarkIntegrityStore()
        try store.saveIssues(task: options.task, issues: scanned)
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
}
