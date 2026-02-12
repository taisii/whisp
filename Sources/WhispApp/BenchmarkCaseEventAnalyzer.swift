import Foundation
import WhispCore

struct BenchmarkCaseTimelinePhase: Equatable, Identifiable {
    let id: String
    let title: String
    let startMs: Double
    let endMs: Double

    var durationMs: Double {
        max(0, endMs - startMs)
    }
}

struct BenchmarkCaseTimelineOverlap: Equatable {
    let leftTitle: String
    let rightTitle: String
    let durationMs: Double
}

struct BenchmarkCaseTimelineSummary: Equatable {
    let phases: [BenchmarkCaseTimelinePhase]
    let totalMs: Double
    let overlap: BenchmarkCaseTimelineOverlap?
    let recordingMs: Double?
    let sttMs: Double?
    let deltaAfterRecordingMs: Double?
    let missingMessages: [String]

    static let empty = BenchmarkCaseTimelineSummary(
        phases: [],
        totalMs: 0,
        overlap: nil,
        recordingMs: nil,
        sttMs: nil,
        deltaAfterRecordingMs: nil,
        missingMessages: []
    )
}

struct BenchmarkCaseEventAnalysis: Equatable {
    let audioFilePath: String?
    let sttLog: BenchmarkSTTLog?
    let timeline: BenchmarkCaseTimelineSummary
}

struct BenchmarkCaseEventAnalyzer {
    func analyze(events: [BenchmarkCaseEvent]) -> BenchmarkCaseEventAnalysis {
        let sorted = events.sorted {
            if $0.base.startedAtMs != $1.base.startedAtMs {
                return $0.base.startedAtMs < $1.base.startedAtMs
            }
            return $0.base.recordedAtMs < $1.base.recordedAtMs
        }

        let loadCaseLog = sorted.compactMap(loadCase).first
        let audioReplayLog = sorted.compactMap(audioReplay).first
        let sttLog = sorted.compactMap(stt).first

        struct Window {
            let id: String
            let title: String
            let startMs: Int64
            let endMs: Int64
        }

        func window(id: String, title: String, startMs: Int64, endMs: Int64) -> Window? {
            guard endMs >= startMs else { return nil }
            return Window(id: id, title: title, startMs: startMs, endMs: endMs)
        }

        var missingMessages: [String] = []
        var windows: [Window] = []
        var recordingWindow: Window?
        var sttWindow: Window?

        if let audioReplayLog {
            if let value = window(
                id: "audio_replay",
                title: "録音(音声再生(疑似録音))",
                startMs: audioReplayLog.base.startedAtMs,
                endMs: audioReplayLog.base.endedAtMs
            ) {
                windows.append(value)
                recordingWindow = value
            } else {
                missingMessages.append("audio_replay イベントの時刻が不正です。")
            }
        } else {
            missingMessages.append("audio_replay イベントがないため、音声再生(疑似録音)のタイムラインを表示できません。")
        }

        if let sttLog {
            if let value = window(
                id: "stt",
                title: "STT",
                startMs: sttLog.base.startedAtMs,
                endMs: sttLog.base.endedAtMs
            ) {
                windows.append(value)
                sttWindow = value
            } else {
                missingMessages.append("stt イベントの時刻が不正です。")
            }
        } else {
            missingMessages.append("stt イベントがないため、STTタイムラインを表示できません。")
        }

        if let recordingWindow, let sttWindow {
            let deltaWindow = Window(
                id: "stt_after_recording",
                title: "差分(録音停止後待ち)",
                startMs: recordingWindow.endMs,
                endMs: max(recordingWindow.endMs, sttWindow.endMs)
            )
            windows.append(deltaWindow)
        }

        let timeline: BenchmarkCaseTimelineSummary
        if windows.isEmpty {
            timeline = BenchmarkCaseTimelineSummary(
                phases: [],
                totalMs: 0,
                overlap: nil,
                recordingMs: nil,
                sttMs: nil,
                deltaAfterRecordingMs: nil,
                missingMessages: missingMessages
            )
        } else {
            let anchor = windows.map(\.startMs).min() ?? 0
            let phases = windows
                .sorted { $0.startMs < $1.startMs }
                .map { value in
                    BenchmarkCaseTimelinePhase(
                        id: value.id,
                        title: value.title,
                        startMs: Double(max(0, value.startMs - anchor)),
                        endMs: Double(max(0, value.endMs - anchor))
                    )
                }
            let totalMs = phases.map(\.endMs).max() ?? 0
            let recordingMs = recordingWindow.map { Double(max(0, $0.endMs - $0.startMs)) }
            let sttMs = sttWindow.map { Double(max(0, $0.endMs - $0.startMs)) }
            let deltaAfterRecordingMs: Double?
            if let recordingWindow, let sttWindow {
                deltaAfterRecordingMs = Double(max(0, sttWindow.endMs - recordingWindow.endMs))
            } else {
                deltaAfterRecordingMs = nil
            }

            let overlap: BenchmarkCaseTimelineOverlap?
            if let replayPhase = phases.first(where: { $0.id == "audio_replay" }),
               let sttPhase = phases.first(where: { $0.id == "stt" })
            {
                let overlapMs = min(replayPhase.endMs, sttPhase.endMs) - max(replayPhase.startMs, sttPhase.startMs)
                if overlapMs > 0 {
                    overlap = BenchmarkCaseTimelineOverlap(
                        leftTitle: replayPhase.title,
                        rightTitle: sttPhase.title,
                        durationMs: overlapMs
                    )
                } else {
                    overlap = nil
                }
            } else {
                overlap = nil
            }

            timeline = BenchmarkCaseTimelineSummary(
                phases: phases,
                totalMs: totalMs,
                overlap: overlap,
                recordingMs: recordingMs,
                sttMs: sttMs,
                deltaAfterRecordingMs: deltaAfterRecordingMs,
                missingMessages: missingMessages
            )
        }

        return BenchmarkCaseEventAnalysis(
            audioFilePath: loadCaseLog?.audioFilePath,
            sttLog: sttLog,
            timeline: timeline
        )
    }

    private func loadCase(_ event: BenchmarkCaseEvent) -> BenchmarkLoadCaseLog? {
        guard case let .loadCase(log) = event else { return nil }
        return log
    }

    private func audioReplay(_ event: BenchmarkCaseEvent) -> BenchmarkAudioReplayLog? {
        guard case let .audioReplay(log) = event else { return nil }
        return log
    }

    private func stt(_ event: BenchmarkCaseEvent) -> BenchmarkSTTLog? {
        guard case let .stt(log) = event else { return nil }
        return log
    }
}
