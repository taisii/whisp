import Foundation
import WhispCore

struct DebugEventAnalyzer {
    private let isoWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let isoBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func analyze(events: [DebugRunEvent]) -> DebugEventAnalysis {
        var providerRaw: String?
        var sourceRaw: String?
        var sawStreamFinalize = false
        var recordingMs: Double?
        var sttMs: Double?
        var sttFinalizeMs: Double?
        var visionWaitMs: Double?
        var visionCaptureMs: Double?
        var visionAnalyzeMs: Double?
        var visionTotalMs: Double?
        var prefersContextSummaryTiming = false
        var postProcessMs: Double?
        var directInputMs: Double?
        var pipelineMs: Double?
        var endToEndMs: Double?

        for event in events {
            switch event.name {
            case .recordingStart:
                if providerRaw == nil {
                    providerRaw = event.field(.sttProvider)
                }
            case .recordingStop:
                recordingMs = parseMs(event.fields, key: .recordingMs)
            case .sttDone:
                sourceRaw = event.field(.source) ?? sourceRaw
                sttMs = parseMs(event.fields, key: .durationMs) ?? sttMs
            case .sttStreamFinalizeDone:
                sawStreamFinalize = true
                sttFinalizeMs = parseMs(event.fields, key: .durationMs)
                if sttMs == nil {
                    sttMs = sttFinalizeMs
                }
            case .visionDone:
                visionWaitMs = parseMs(event.fields, key: .waitMs)
                visionCaptureMs = parseMs(event.fields, key: .captureMs)
                visionAnalyzeMs = parseMs(event.fields, key: .analyzeMs)
                if !prefersContextSummaryTiming {
                    visionTotalMs = parseMs(event.fields, key: .totalMs)
                }
            case .contextSummaryDone:
                prefersContextSummaryTiming = true
                visionTotalMs = parseMs(event.fields, key: .durationMs)
            case .postprocessDone, .audioLLMDone:
                postProcessMs = parseMs(event.fields, key: .durationMs)
            case .directInputDone:
                directInputMs = parseMs(event.fields, key: .durationMs)
            case .pipelineDone:
                pipelineMs = parseMs(event.fields, key: .pipelineMs)
                endToEndMs = parseMs(event.fields, key: .endToEndMs)
            case .pipelineError:
                if pipelineMs == nil {
                    pipelineMs = parseMs(event.fields, key: .elapsedMs)
                }
            default:
                break
            }
        }

        let provider = providerRaw.flatMap(STTProvider.init(rawValue:))
        let source = sourceRaw.flatMap(DebugSTTSource.init(rawValue:))

        let providerName: String = {
            switch provider {
            case .deepgram:
                return "Deepgram"
            case .whisper:
                return "Whisper (OpenAI)"
            case .appleSpeech:
                return "Apple Speech"
            case nil:
                switch source {
                case .whisper, .whisperREST:
                    return "Whisper (OpenAI)"
                case .appleSpeech:
                    return "Apple Speech"
                case .rest, .restFallback:
                    return "Deepgram"
                case nil:
                    return "不明"
                }
            }
        }()

        let routeName: String = {
            if sawStreamFinalize {
                return "Streaming"
            }
            switch source {
            case .rest:
                return "REST"
            case .restFallback:
                return "Streaming失敗 → REST"
            case .whisperREST:
                return "REST"
            case .appleSpeech:
                return "On-device"
            case .whisper:
                return "whisper"
            case nil:
                return sourceRaw ?? "不明"
            }
        }()

        let timings = DebugPhaseTimingSummary(
            recordingMs: recordingMs,
            sttMs: sttMs,
            sttFinalizeMs: sttFinalizeMs,
            visionWaitMs: visionWaitMs,
            visionCaptureMs: visionCaptureMs,
            visionAnalyzeMs: visionAnalyzeMs,
            visionTotalMs: visionTotalMs,
            postProcessMs: postProcessMs,
            directInputMs: directInputMs,
            pipelineMs: pipelineMs,
            endToEndMs: endToEndMs
        )
        let timeline = buildTimeline(events: events, timings: timings)

        return DebugEventAnalysis(
            sttInfo: DebugSTTExecutionInfo(providerName: providerName, routeName: routeName),
            timings: timings,
            timeline: timeline
        )
    }

    private func parseMs(_ fields: [String: String], key: DebugRunEventField) -> Double? {
        guard let raw = fields[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return Double(raw)
    }

    private func buildTimeline(events: [DebugRunEvent], timings: DebugPhaseTimingSummary) -> DebugTimelineSummary {
        struct Window {
            let id: String
            let title: String
            let start: Date
            let end: Date
        }

        func firstEvent(named name: DebugRunEventName) -> DebugRunEvent? {
            events.first { $0.name == name }
        }

        var firstAt: [DebugRunEventName: Date] = [:]
        for event in events {
            guard let name = event.name, firstAt[name] == nil, let timestamp = parseEventTimestamp(event.timestamp) else {
                continue
            }
            firstAt[name] = timestamp
        }

        func eventDate(_ event: DebugRunEvent?, preferredField: DebugRunEventField? = nil) -> Date? {
            guard let event else { return nil }
            if let preferredField,
               let parsed = parseEpochMsDate(event.fields, key: preferredField)
            {
                return parsed
            }
            return parseEventTimestamp(event.timestamp)
        }

        func resolvedWindow(
            id: String,
            title: String,
            start: Date?,
            end: Date?,
            fallbackMs: Double?
        ) -> Window? {
            var startDate = start
            var endDate = end
            if startDate == nil, let endDate, let fallbackMs {
                startDate = endDate.addingTimeInterval(-fallbackMs / 1000)
            }
            if endDate == nil, let startDate, let fallbackMs {
                endDate = startDate.addingTimeInterval(fallbackMs / 1000)
            }
            guard let startDate, let endDate, endDate >= startDate else {
                return nil
            }
            return Window(id: id, title: title, start: startDate, end: endDate)
        }

        var windows: [Window] = []

        let pipelineEndAt = firstAt[.pipelineDone] ?? firstAt[.pipelineError]
        let recordingStartEvent = firstEvent(named: .recordingStart)
        let recordingStopEvent = firstEvent(named: .recordingStop)
        if let window = resolvedWindow(
            id: "recording",
            title: "録音",
            start: eventDate(recordingStartEvent, preferredField: .recordingStartedAtMs),
            end: eventDate(recordingStopEvent, preferredField: .recordingStoppedAtMs),
            fallbackMs: timings.recordingMs
        ) {
            windows.append(window)
        }

        let recordingSavedAt = firstAt[.recordingSaved]
        if !windows.contains(where: { $0.id == "recording" }),
           let pipelineEndAt,
           let endToEndMs = timings.endToEndMs,
           let pipelineMs = timings.pipelineMs
        {
            let recordingStart = pipelineEndAt.addingTimeInterval(-endToEndMs / 1000)
            let recordingEnd = pipelineEndAt.addingTimeInterval(-pipelineMs / 1000)
            if let window = resolvedWindow(
                id: "recording",
                title: "録音",
                start: recordingStart,
                end: recordingEnd,
                fallbackMs: timings.recordingMs
            ) {
                windows.append(window)
            }
        } else if !windows.contains(where: { $0.id == "recording" }), let recordingSavedAt {
            if let window = resolvedWindow(
                id: "recording",
                title: "録音",
                start: nil,
                end: recordingSavedAt,
                fallbackMs: timings.recordingMs
            ) {
                windows.append(window)
            }
        }

        let sttDoneEvent = firstEvent(named: .sttDone)
        let sttFinalizeDoneEvent = firstEvent(named: .sttStreamFinalizeDone)
        let sttStartEvent = firstEvent(named: .sttStart)
        let sttFinalizeStartEvent = firstEvent(named: .sttStreamFinalizeStart)
        let sttStartDate: Date? = {
            if sttDoneEvent != nil {
                return eventDate(sttStartEvent, preferredField: .requestSentAtMs)
            }
            return eventDate(sttFinalizeStartEvent, preferredField: .requestSentAtMs)
        }()
        let sttEndDate: Date? = {
            if sttDoneEvent != nil {
                return eventDate(sttDoneEvent, preferredField: .responseReceivedAtMs)
            }
            return eventDate(sttFinalizeDoneEvent, preferredField: .responseReceivedAtMs)
        }()
        if let window = resolvedWindow(
            id: "stt",
            title: "STT",
            start: sttStartDate,
            end: sttEndDate,
            fallbackMs: timings.sttMs ?? timings.sttFinalizeMs
        ) {
            windows.append(window)
        }

        let contextSummaryStartEvent = firstEvent(named: .contextSummaryStart)
        let contextSummaryEndEvent = firstEvent(named: .contextSummaryDone)
            ?? firstEvent(named: .contextSummaryFailed)
        if contextSummaryStartEvent != nil || contextSummaryEndEvent != nil {
            if let window = resolvedWindow(
                id: "context_summary",
                title: "文脈要約",
                start: eventDate(contextSummaryStartEvent, preferredField: .requestSentAtMs),
                end: eventDate(contextSummaryEndEvent, preferredField: .responseReceivedAtMs),
                fallbackMs: timings.visionTotalMs
            ) {
                windows.append(window)
            }
        } else {
            let visionStartEvent = firstEvent(named: .visionStart)
            let visionEndEvent = firstEvent(named: .visionDone)
                ?? firstEvent(named: .visionSkippedNotReady)
                ?? firstEvent(named: .visionCollectFailed)
            if let window = resolvedWindow(
                id: "vision",
                title: "Vision",
                start: eventDate(visionStartEvent, preferredField: .requestSentAtMs),
                end: eventDate(visionEndEvent, preferredField: .responseReceivedAtMs),
                fallbackMs: timings.visionTotalMs
            ) {
                windows.append(window)
            }
        }

        if let window = resolvedWindow(
            id: "postprocess",
            title: "整形",
            start: firstAt[.postprocessStart] ?? firstAt[.audioLLMStart],
            end: firstAt[.postprocessDone] ?? firstAt[.audioLLMDone],
            fallbackMs: timings.postProcessMs
        ) {
            windows.append(window)
        }

        if let window = resolvedWindow(
            id: "direct_input",
            title: "DirectInput",
            start: nil,
            end: firstAt[.directInputDone],
            fallbackMs: timings.directInputMs
        ) {
            windows.append(window)
        }

        if let window = resolvedWindow(
            id: "pipeline",
            title: "Pipeline(stop後)",
            start: nil,
            end: pipelineEndAt,
            fallbackMs: timings.pipelineMs
        ) {
            windows.append(window)
        }

        guard !windows.isEmpty else {
            return .empty
        }

        let anchor = windows.map(\.start).min() ?? Date()
        let phases = windows
            .sorted { $0.start < $1.start }
            .map { window in
                DebugTimelinePhase(
                    id: window.id,
                    title: window.title,
                    startMs: max(0, window.start.timeIntervalSince(anchor) * 1000),
                    endMs: max(0, window.end.timeIntervalSince(anchor) * 1000)
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

    private func parseEventTimestamp(_ value: String) -> Date? {
        if let parsed = isoWithFractionalSeconds.date(from: value) {
            return parsed
        }
        return isoBasic.date(from: value)
    }

    private func parseEpochMsDate(_ fields: [String: String], key: DebugRunEventField) -> Date? {
        guard let raw = fields[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(raw)
        else {
            return nil
        }
        return Date(timeIntervalSince1970: value / 1000)
    }
}
