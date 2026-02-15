import Foundation
import XCTest
@testable import WhispCore

final class TemporaryOpenAIRecheckTests: XCTestCase {
    private struct RealtimePattern: Sendable {
        let name: String
        let sessionModel: String
        let transcriptionModel: String
        let sampleRate: Int
        let pcmBytes: Data
        let chunkMs: Int
    }

    func testRecheckOpenAIAfterKeyUpdate() async throws {
        let datasetPath = ("~/.config/whisp/debug/manual_test_cases.jsonl" as NSString).expandingTildeInPath
        let cases = try BenchmarkExecutor.loadManualBenchmarkCases(path: datasetPath)
        guard let first = cases.first else {
            XCTFail("manual test case がありません")
            return
        }

        let wav = try Data(contentsOf: URL(fileURLWithPath: first.audioFile))
        let audio16 = try parsePCM16MonoWAV(wav)
        let samples16 = decodePCM16(audio16.pcmBytes)
        let samples24 = resampleLinearPCM16(samples: samples16, from: Int(audio16.sampleRate), to: 24_000)
        let audio24 = encodePCM16(samples24)

        let config = try BenchmarkExecutor.loadConfig()
        let credential = try APIKeyResolver.sttCredential(config: config, preset: .chatgptWhisperStream)
        guard case let .apiKey(apiKey) = credential else {
            XCTFail("OpenAI API key が取得できません")
            return
        }

        print("recheck_start")

        do {
            let started = Date()
            let rest = try await WhisperClient().transcribe(
                apiKey: apiKey,
                sampleRate: Int(audio16.sampleRate),
                audio: audio16.pcmBytes,
                language: nil
            )
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
            print("check=rest\tstatus=ok\tchars=\(rest.transcript.count)\telapsed_ms=\(elapsedMs)")
        } catch {
            print("check=rest\tstatus=error\terror=\(error.localizedDescription)")
        }

        let patterns: [RealtimePattern] = [
            RealtimePattern(
                name: "current_16k",
                sessionModel: OpenAIRealtimeStreamingClient.defaultSessionModel,
                transcriptionModel: OpenAIRealtimeStreamingClient.defaultTranscriptionModel,
                sampleRate: Int(audio16.sampleRate),
                pcmBytes: audio16.pcmBytes,
                chunkMs: 120
            ),
            RealtimePattern(
                name: "current_24k",
                sessionModel: OpenAIRealtimeStreamingClient.defaultSessionModel,
                transcriptionModel: OpenAIRealtimeStreamingClient.defaultTranscriptionModel,
                sampleRate: 24_000,
                pcmBytes: audio24,
                chunkMs: 120
            ),
            RealtimePattern(
                name: "gpt_realtime_24k",
                sessionModel: "gpt-realtime",
                transcriptionModel: "gpt-4o-transcribe",
                sampleRate: 24_000,
                pcmBytes: audio24,
                chunkMs: 120
            ),
        ]

        for pattern in patterns {
            do {
                let started = Date()
                let transcript = try await runRealtime(apiKey: apiKey, pattern: pattern)
                let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
                print("check=realtime[\(pattern.name)]\tstatus=ok\tchars=\(transcript.count)\telapsed_ms=\(elapsedMs)")
            } catch {
                let elapsedMs = Int(Date().timeIntervalSince(startedAt: Date(), until: Date()) * 1_000)
                print("check=realtime[\(pattern.name)]\tstatus=error\telapsed_ms=\(elapsedMs)\terror=\(error.localizedDescription)")
            }
        }

        await runBenchmarkOnce(
            datasetPath: datasetPath,
            benchmarkWorkers: 4,
            compareWorkers: 2
        )
        await runBenchmarkOnce(
            datasetPath: datasetPath,
            benchmarkWorkers: 1,
            compareWorkers: 1
        )

        print("recheck_done")
    }

    private func runRealtime(apiKey: String, pattern: RealtimePattern) async throws -> String {
        let stream = OpenAIRealtimeStreamingClient()
        try await stream.start(
            apiKey: apiKey,
            sampleRate: pattern.sampleRate,
            language: nil,
            sessionModel: pattern.sessionModel,
            transcriptionModel: pattern.transcriptionModel
        )
        let chunks = splitChunks(
            pcmBytes: pattern.pcmBytes,
            sampleRate: pattern.sampleRate,
            chunkMs: pattern.chunkMs
        )
        for chunk in chunks {
            await stream.enqueueAudioChunk(chunk)
        }
        let result = try await stream.finish()
        return result.transcript
    }

    private func runBenchmarkOnce(
        datasetPath: String,
        benchmarkWorkers: Int,
        compareWorkers: Int
    ) async {
        do {
            let request = BenchmarkExecutionRequest(
                flow: .stt,
                datasetPath: datasetPath,
                candidateIDs: ["stt-chatgpt-whisper-stream-default"],
                force: true,
                benchmarkWorkers: benchmarkWorkers,
                compareWorkers: compareWorkers
            )
            let started = Date()
            try await BenchmarkExecutionService().runCompare(request: request)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
            let store = BenchmarkStore()
            let runs = try store.listRuns(limit: 20)
            let matched = runs.first {
                $0.kind == .stt && $0.candidateID == "stt-chatgpt-whisper-stream-default"
            }
            if let matched,
               case let .stt(metrics) = matched.metrics
            {
                print(
                    "check=benchmark[bw=\(benchmarkWorkers),cw=\(compareWorkers)]\tstatus=ok\trun_id=\(matched.id)\texecuted=\(metrics.counts.executedCases)\tfailed=\(metrics.counts.failedCases)\telapsed_ms=\(elapsedMs)"
                )
            } else {
                print("check=benchmark[bw=\(benchmarkWorkers),cw=\(compareWorkers)]\tstatus=unknown\tno_run")
            }
        } catch {
            print("check=benchmark[bw=\(benchmarkWorkers),cw=\(compareWorkers)]\tstatus=error\terror=\(error.localizedDescription)")
        }
    }

    private func splitChunks(
        pcmBytes: Data,
        sampleRate: Int,
        chunkMs: Int
    ) -> [Data] {
        let framesPerChunk = max(1, sampleRate * chunkMs / 1_000)
        let chunkBytes = framesPerChunk * MemoryLayout<Int16>.size
        if pcmBytes.isEmpty {
            return []
        }
        var chunks: [Data] = []
        var offset = 0
        while offset < pcmBytes.count {
            let end = min(offset + chunkBytes, pcmBytes.count)
            chunks.append(pcmBytes.subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }

    private func decodePCM16(_ data: Data) -> [Int16] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        return data.withUnsafeBytes { raw in
            let typed = raw.bindMemory(to: Int16.self)
            return Array(typed.prefix(sampleCount))
        }
    }

    private func encodePCM16(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    private func resampleLinearPCM16(samples: [Int16], from sourceRate: Int, to targetRate: Int) -> [Int16] {
        guard sourceRate > 0, targetRate > 0 else { return samples }
        guard !samples.isEmpty else { return samples }
        if sourceRate == targetRate { return samples }

        let ratio = Double(targetRate) / Double(sourceRate)
        let outputCount = max(1, Int((Double(samples.count) * ratio).rounded(.toNearestOrAwayFromZero)))
        var output = Array(repeating: Int16(0), count: outputCount)

        for index in 0..<outputCount {
            let sourcePosition = Double(index) / ratio
            let leftIndex = Int(sourcePosition)
            if leftIndex >= samples.count - 1 {
                output[index] = samples[samples.count - 1]
                continue
            }
            let rightIndex = leftIndex + 1
            let fraction = sourcePosition - Double(leftIndex)
            let left = Double(samples[leftIndex])
            let right = Double(samples[rightIndex])
            let interpolated = left + ((right - left) * fraction)
            let clamped = max(Double(Int16.min), min(Double(Int16.max), interpolated.rounded()))
            output[index] = Int16(clamped)
        }

        return output
    }
}

private extension Date {
    func timeIntervalSince(startedAt: Date, until end: Date) -> TimeInterval {
        end.timeIntervalSince(startedAt)
    }
}
