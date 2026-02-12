import Foundation
import XCTest
@testable import WhispCore

final class WhispPathsTests: XCTestCase {
    func testPathsAreDerivedFromHomeDirectory() throws {
        let paths = try WhispPaths(environment: ["HOME": "/tmp/test-home"])

        XCTAssertEqual(paths.baseDirectory.path, "/tmp/test-home/.config/whisp")
        XCTAssertEqual(paths.configFile.path, "/tmp/test-home/.config/whisp/config.json")
        XCTAssertEqual(paths.usageFile.path, "/tmp/test-home/.config/whisp/usage.json")
        XCTAssertEqual(paths.debugDirectory.path, "/tmp/test-home/.config/whisp/debug")
        XCTAssertEqual(paths.runsDirectory.path, "/tmp/test-home/.config/whisp/debug/runs")
        XCTAssertEqual(paths.benchmarkDirectory.path, "/tmp/test-home/.config/whisp/debug/benchmarks")
        XCTAssertEqual(paths.benchmarkRunsDirectory.path, "/tmp/test-home/.config/whisp/debug/benchmarks/runs")
        XCTAssertEqual(paths.benchmarkCandidatesDirectory.path, "/tmp/test-home/.config/whisp/debug/benchmarks/candidates")
        XCTAssertEqual(paths.benchmarkIntegrityDirectory.path, "/tmp/test-home/.config/whisp/debug/benchmarks/integrity")
        XCTAssertEqual(paths.statsDirectory.path, "/tmp/test-home/.config/whisp/debug/stats")
        XCTAssertEqual(paths.runtimeStatsFile.path, "/tmp/test-home/.config/whisp/debug/stats/runtime_stats.json")
        XCTAssertEqual(paths.manualCasesFile.path, "/tmp/test-home/.config/whisp/debug/manual_test_cases.jsonl")
        XCTAssertEqual(paths.promptDefaultDirectory.path, "/tmp/test-home/.config/whisp/debug/runs/_default/prompts")
        XCTAssertEqual(paths.devLogFile.path, "/tmp/test-home/.config/whisp/dev.log")
        XCTAssertEqual(paths.benchmarkCacheDirectory.path, "/tmp/test-home/.config/whisp/benchmark_cache")
    }

    func testMissingHomeThrowsWhenFallbackDisabled() {
        XCTAssertThrowsError(try WhispPaths(environment: [:], allowTemporaryFallback: false))
    }
}
