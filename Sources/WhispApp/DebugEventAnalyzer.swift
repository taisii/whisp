import Foundation
import WhispCore

struct DebugEventAnalyzer {
    func analyze(logs: [DebugRunLog]) -> DebugEventAnalysis {
        let recordingLog = firstLog(in: logs, type: .recording)
        let sttLog = firstLog(in: logs, type: .stt)
        let visionLog = firstLog(in: logs, type: .vision)
        let contextSummaryLog = firstLog(in: logs, type: .contextSummary)
        let postprocessLog = firstLog(in: logs, type: .postprocess)
        let directInputLog = firstLog(in: logs, type: .directInput)
        let pipelineLog = firstLog(in: logs, type: .pipeline)

        let sttInfo = resolveSTTInfo(sttLog)
        let sttFinalizeMs = resolveSTTFinalizeMs(sttLog)

        let recordingMs = durationMs(recordingLog)
        let sttMs = durationMs(sttLog)
        let visionMs = durationMs(contextSummaryLog) ?? durationMs(visionLog)
        let postprocessMs = durationMs(postprocessLog)
        let directInputMs = durationMs(directInputLog)
        let pipelineMs = durationMs(pipelineLog)
        let endToEndMs = endToEndDuration(recordingLog: recordingLog, pipelineLog: pipelineLog)

        let timings = DebugPhaseTimingSummary(
            recordingMs: recordingMs,
            sttMs: sttMs,
            sttFinalizeMs: sttFinalizeMs,
            visionTotalMs: visionMs,
            postProcessMs: postprocessMs,
            directInputMs: directInputMs,
            pipelineMs: pipelineMs,
            endToEndMs: endToEndMs
        )
        let timeline = buildTimeline(
            recordingLog: recordingLog,
            sttLog: sttLog,
            contextSummaryLog: contextSummaryLog,
            visionLog: visionLog,
            postprocessLog: postprocessLog,
            directInputLog: directInputLog,
            pipelineLog: pipelineLog
        )

        return DebugEventAnalysis(
            sttInfo: sttInfo,
            timings: timings,
            timeline: timeline
        )
    }

    private func buildTimeline(
        recordingLog: DebugRunLog?,
        sttLog: DebugRunLog?,
        contextSummaryLog: DebugRunLog?,
        visionLog: DebugRunLog?,
        postprocessLog: DebugRunLog?,
        directInputLog: DebugRunLog?,
        pipelineLog: DebugRunLog?
    ) -> DebugTimelineSummary {
        struct Window {
            let id: String
            let title: String
            let startMs: Int64
            let endMs: Int64
        }

        func window(id: String, title: String, from log: DebugRunLog?) -> Window? {
            guard let log else { return nil }
            let start = log.base.eventStartMs
            let end = log.base.eventEndMs
            guard end >= start else { return nil }
            return Window(id: id, title: title, startMs: start, endMs: end)
        }

        var windows: [Window] = []
        if let value = window(id: "recording", title: "録音", from: recordingLog) {
            windows.append(value)
        }
        if let value = window(id: "stt", title: "STT", from: sttLog) {
            windows.append(value)
        }
        if let value = window(id: "context_summary", title: "文脈要約", from: contextSummaryLog) {
            windows.append(value)
        } else if let value = window(id: "vision", title: "Vision", from: visionLog) {
            windows.append(value)
        }
        if let value = window(id: "postprocess", title: "整形", from: postprocessLog) {
            windows.append(value)
        }
        if let value = window(id: "direct_input", title: "DirectInput", from: directInputLog) {
            windows.append(value)
        }
        if let value = window(id: "pipeline", title: "Pipeline(stop後)", from: pipelineLog) {
            windows.append(value)
        }

        guard !windows.isEmpty else {
            return .empty
        }

        let anchor = windows.map(\.startMs).min() ?? 0
        let phases = windows
            .sorted { $0.startMs < $1.startMs }
            .map { value in
                DebugTimelinePhase(
                    id: value.id,
                    title: value.title,
                    startMs: Double(max(0, value.startMs - anchor)),
                    endMs: Double(max(0, value.endMs - anchor))
                )
            }

        let totalMs = phases.map(\.endMs).max() ?? 0
        let bottleneckCandidates = phases.filter { ["stt", "vision", "context_summary", "postprocess", "direct_input"].contains($0.id) }
        let bottleneckPhaseID = bottleneckCandidates.max { $0.durationMs < $1.durationMs }?.id

        var maxOverlap: DebugTimelineOverlap?
        for leftIndex in bottleneckCandidates.indices {
            for rightIndex in bottleneckCandidates.indices where rightIndex > leftIndex {
                let left = bottleneckCandidates[leftIndex]
                let right = bottleneckCandidates[rightIndex]
                let overlap = min(left.endMs, right.endMs) - max(left.startMs, right.startMs)
                guard overlap > 0 else { continue }
                if maxOverlap == nil || overlap > (maxOverlap?.durationMs ?? 0) {
                    maxOverlap = DebugTimelineOverlap(
                        leftPhaseID: left.id,
                        rightPhaseID: right.id,
                        leftTitle: left.title,
                        rightTitle: right.title,
                        durationMs: overlap
                    )
                }
            }
        }

        return DebugTimelineSummary(
            phases: phases,
            totalMs: totalMs,
            bottleneckPhaseID: bottleneckPhaseID,
            maxOverlap: maxOverlap
        )
    }

    private func resolveSTTInfo(_ sttLog: DebugRunLog?) -> DebugSTTExecutionInfo {
        guard case let .stt(log)? = sttLog else {
            return .unknown
        }

        let providerName: String = {
            if let preset = STTPresetID(rawValue: log.provider) {
                return STTPresetCatalog.spec(for: preset).displayName
            }
            switch log.provider {
            case STTProvider.deepgram.rawValue:
                return "Deepgram (legacy)"
            case STTProvider.whisper.rawValue:
                return "Whisper (legacy)"
            case STTProvider.appleSpeech.rawValue:
                return "Apple Speech (legacy)"
            default:
                return "不明 (\(log.provider))"
            }
        }()

        let routeName: String = {
            switch log.route {
            case .streaming:
                return "Streaming"
            case .rest:
                return "REST"
            case .streamingFallbackREST:
                return "Streaming失敗 → REST"
            case .onDevice:
                return "On-device"
            }
        }()

        return DebugSTTExecutionInfo(providerName: providerName, routeName: routeName)
    }

    private func resolveSTTFinalizeMs(_ sttLog: DebugRunLog?) -> Double? {
        guard case let .stt(log)? = sttLog else {
            return nil
        }
        guard let attempt = log.attempts.first(where: { $0.kind == .streamFinalize }) else {
            return nil
        }
        guard attempt.eventEndMs >= attempt.eventStartMs else {
            return nil
        }
        return Double(attempt.eventEndMs - attempt.eventStartMs)
    }

    private func endToEndDuration(recordingLog: DebugRunLog?, pipelineLog: DebugRunLog?) -> Double? {
        guard let recordingLog, let pipelineLog else {
            return nil
        }
        let start = recordingLog.base.eventStartMs
        let end = pipelineLog.base.eventEndMs
        guard end >= start else {
            return nil
        }
        return Double(end - start)
    }

    private func durationMs(_ log: DebugRunLog?) -> Double? {
        guard let log else { return nil }
        let start = log.base.eventStartMs
        let end = log.base.eventEndMs
        guard end >= start else {
            return nil
        }
        return Double(end - start)
    }

    private func firstLog(in logs: [DebugRunLog], type: DebugLogType) -> DebugRunLog? {
        logs
            .filter { $0.base.logType == type }
            .sorted { $0.base.eventStartMs < $1.base.eventStartMs }
            .first
    }
}
