import AppKit
import Foundation
import WhispCore

struct DebugRunArtifacts {
    let captureID: String?
    let runDirectory: String?
    let accessibilityContext: ContextInfo?
}

final class DebugCaptureService: @unchecked Sendable {
    private let store: DebugCaptureStore

    init(store: DebugCaptureStore = .shared) {
        self.store = store
    }

    var capturesDirectoryPath: String {
        store.capturesDirectoryPath
    }

    func reserveRun(
        runID: String,
        config: Config,
        frontmostApp: NSRunningApplication?,
        accessibility: AccessibilityContextCapture?
    ) -> DebugRunArtifacts {
        do {
            let captureID = try store.reserveRun(
                runID: runID,
                llmModel: config.llmModel.rawValue,
                appName: frontmostApp?.localizedName,
                accessibilitySnapshot: accessibility?.snapshot
            )
            let runDirectory = try store.runDirectoryPath(captureID: captureID)
            return DebugRunArtifacts(
                captureID: captureID,
                runDirectory: runDirectory,
                accessibilityContext: accessibility?.context
            )
        } catch {
            DevLog.info("debug_capture_reserve_failed", fields: [
                "run": runID,
                "error": error.localizedDescription,
            ])
            return DebugRunArtifacts(
                captureID: nil,
                runDirectory: nil,
                accessibilityContext: accessibility?.context
            )
        }
    }

    func saveRecording(
        runID: String,
        recording: RecordingResult,
        config: Config,
        frontmostApp: NSRunningApplication?,
        accessibility: AccessibilityContextCapture?,
        existingArtifacts: DebugRunArtifacts? = nil
    ) -> DebugRunArtifacts {
        guard !recording.pcmData.isEmpty || existingArtifacts?.captureID != nil else {
            return DebugRunArtifacts(
                captureID: nil,
                runDirectory: nil,
                accessibilityContext: accessibility?.context
            )
        }

        do {
            let captureID = try store.saveRecording(
                runID: runID,
                sampleRate: recording.sampleRate,
                pcmData: recording.pcmData,
                llmModel: config.llmModel.rawValue,
                appName: frontmostApp?.localizedName,
                captureID: existingArtifacts?.captureID,
                accessibilitySnapshot: accessibility?.snapshot
            )
            let runDirectory = try store.runDirectoryPath(captureID: captureID) ?? existingArtifacts?.runDirectory
            return DebugRunArtifacts(
                captureID: captureID,
                runDirectory: runDirectory,
                accessibilityContext: accessibility?.context
            )
        } catch {
            DevLog.info("debug_capture_save_failed", fields: [
                "run": runID,
                "error": error.localizedDescription,
            ])
            return DebugRunArtifacts(
                captureID: nil,
                runDirectory: nil,
                accessibilityContext: accessibility?.context
            )
        }
    }

    func appendLog(captureID: String?, log: DebugRunLog) {
        guard let captureID else { return }
        do {
            try store.appendLog(captureID: captureID, log: log)
        } catch {
            DevLog.info("debug_capture_log_append_failed", fields: [
                "capture_id": captureID,
                "log_type": log.base.logType.rawValue,
                "error": error.localizedDescription,
            ])
        }
    }

    func updateResult(
        captureID: String?,
        sttText: String?,
        outputText: String?,
        segments: [STTCommittedSegment]? = nil,
        vadIntervals: [VADInterval]? = nil,
        status: String,
        skipReason: String? = nil,
        failureStage: String? = nil,
        metrics: DebugRunMetrics? = nil,
        errorMessage: String? = nil
    ) {
        guard let captureID else { return }
        do {
            try store.updateResult(
                captureID: captureID,
                sttText: sttText,
                outputText: outputText,
                segments: segments,
                vadIntervals: vadIntervals,
                status: status,
                skipReason: skipReason,
                failureStage: failureStage,
                metrics: metrics,
                errorMessage: errorMessage
            )
        } catch {
            DevLog.info("debug_capture_update_failed", fields: [
                "capture_id": captureID,
                "status": status,
                "error": error.localizedDescription,
            ])
        }
    }

    func updateContext(captureID: String?, context: ContextInfo?) {
        guard let captureID else { return }
        do {
            try store.updateContext(captureID: captureID, context: context)
        } catch {
            DevLog.info("debug_capture_context_update_failed", fields: [
                "capture_id": captureID,
                "error": error.localizedDescription,
            ])
        }
    }

    func persistVisionArtifacts(captureID: String?, result: VisionContextCollectionResult?) {
        guard let captureID, let result else { return }
        do {
            try store.saveVisionArtifacts(
                captureID: captureID,
                context: result.context,
                imageData: result.imageData,
                imageMimeType: result.imageMimeType
            )
        } catch {
            DevLog.info("debug_capture_vision_artifacts_save_failed", fields: [
                "capture_id": captureID,
                "error": error.localizedDescription,
            ])
        }
    }

    func deleteCapture(captureID: String?) {
        guard let captureID else { return }
        do {
            try store.deleteCapture(captureID: captureID)
        } catch {
            DevLog.info("debug_capture_delete_failed", fields: [
                "capture_id": captureID,
                "error": error.localizedDescription,
            ])
        }
    }
}
