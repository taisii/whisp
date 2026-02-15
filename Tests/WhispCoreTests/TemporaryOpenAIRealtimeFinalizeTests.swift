import Foundation
import XCTest
@testable import WhispCore

final class TemporaryOpenAIRealtimeFinalizeTests: XCTestCase {
    func testRealtimeFinalizeWithResponseCreate() async throws {
        let datasetPath = ("~/.config/whisp/debug/manual_test_cases.jsonl" as NSString).expandingTildeInPath
        let cases = try BenchmarkExecutor.loadManualBenchmarkCases(path: datasetPath)
        guard let first = cases.first else {
            XCTFail("manual test case がありません")
            return
        }

        let wav = try Data(contentsOf: URL(fileURLWithPath: first.audioFile))
        let audio = try parsePCM16MonoWAV(wav)
        let samples16 = decodePCM16(audio.pcmBytes)
        let samples24 = resampleLinearPCM16(samples: samples16, from: Int(audio.sampleRate), to: 24_000)
        let pcm24 = encodePCM16(samples24)

        let config = try BenchmarkExecutor.loadConfig()
        let credential = try APIKeyResolver.sttCredential(config: config, preset: .chatgptWhisperStream)
        guard case let .apiKey(apiKey) = credential else {
            XCTFail("OpenAI API key が取得できません")
            return
        }

        let patterns: [(name: String, sessionModel: String, transcriptionModel: String)] = [
            ("mini_transcribe_session", "gpt-4o-mini-transcribe", "gpt-4o-mini-transcribe"),
            ("realtime_mini_plus_mini_transcribe", "gpt-realtime-mini", "gpt-4o-mini-transcribe"),
            ("realtime_mini_plus_realtime_mini", "gpt-realtime-mini", "gpt-realtime-mini"),
            ("realtime_plus_mini_transcribe", "gpt-realtime", "gpt-4o-mini-transcribe"),
            ("realtime_plus_4o_transcribe", "gpt-realtime", "gpt-4o-transcribe"),
            ("legacy_realtime_preview", "gpt-4o-mini-realtime-preview", "gpt-4o-mini-transcribe"),
            ("legacy_realtime_preview_4o_transcribe", "gpt-4o-mini-realtime-preview", "gpt-4o-transcribe"),
        ]

        for pattern in patterns {
            do {
                let started = Date()
                let transcript = try await runRealtime(
                    apiKey: apiKey,
                    sampleRate: 24_000,
                    pcmBytes: pcm24,
                    sessionModel: pattern.sessionModel,
                    transcriptionModel: pattern.transcriptionModel
                )
                let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
                print("check=realtime[\(pattern.name)]\tstatus=ok\tchars=\(transcript.count)\telapsed_ms=\(elapsedMs)")
            } catch {
                print("check=realtime[\(pattern.name)]\tstatus=error\terror=\(error.localizedDescription)")
            }
        }
    }

    private func runRealtime(
        apiKey: String,
        sampleRate: Int,
        pcmBytes: Data,
        sessionModel: String,
        transcriptionModel: String
    ) async throws -> String {
        let stream = OpenAIRealtimeStreamingClient()
        try await stream.start(
            apiKey: apiKey,
            sampleRate: sampleRate,
            language: nil,
            sessionModel: sessionModel,
            transcriptionModel: transcriptionModel
        )
        let chunkSamples = max(1, sampleRate * 120 / 1_000)
        let chunkBytes = chunkSamples * MemoryLayout<Int16>.size
        var offset = 0
        while offset < pcmBytes.count {
            let end = min(offset + chunkBytes, pcmBytes.count)
            await stream.enqueueAudioChunk(pcmBytes.subdata(in: offset..<end))
            offset = end
        }
        let result = try await stream.finish()
        return result.transcript
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
