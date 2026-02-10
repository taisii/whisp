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

    func saveRecording(
        runID: String,
        recording: RecordingResult,
        config: Config,
        frontmostApp: NSRunningApplication?,
        accessibility: AccessibilityContextCapture?
    ) -> DebugRunArtifacts {
        guard !recording.pcmData.isEmpty else {
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
                accessibilitySnapshot: accessibility?.snapshot
            )
            let runDirectory = try store.runDirectoryPath(captureID: captureID)
            if let accessibilitySnapshot = accessibility?.snapshot {
                appendRecordingSavedEvent(
                    captureID: captureID,
                    runID: runID,
                    recording: recording,
                    accessibility: accessibilitySnapshot
                )
            }
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

    func appendEvent(captureID: String?, event: String, fields: [String: String], timestamp: Date? = nil) {
        guard let captureID else { return }
        do {
            try store.appendEvent(captureID: captureID, event: event, fields: fields, timestamp: timestamp)
        } catch {
            DevLog.info("debug_capture_event_append_failed", fields: [
                "capture_id": captureID,
                "event": event,
                "error": error.localizedDescription,
            ])
        }
    }

    func appendEvent(
        captureID: String?,
        event: DebugRunEventName,
        fields: [String: String],
        timestamp: Date? = nil
    ) {
        appendEvent(captureID: captureID, event: event.rawValue, fields: fields, timestamp: timestamp)
    }

    func updateResult(
        captureID: String?,
        sttText: String?,
        outputText: String?,
        status: String,
        errorMessage: String? = nil
    ) {
        guard let captureID else { return }
        do {
            try store.updateResult(
                captureID: captureID,
                sttText: sttText,
                outputText: outputText,
                status: status,
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

    private func appendRecordingSavedEvent(
        captureID: String,
        runID: String,
        recording: RecordingResult,
        accessibility: AccessibilitySnapshot
    ) {
        do {
            try store.appendEvent(captureID: captureID, event: .recordingSaved, fields: [
                "run": runID,
                DebugRunEventField.sampleRate.rawValue: String(recording.sampleRate),
                DebugRunEventField.audioBytes.rawValue: String(recording.pcmData.count),
                "accessibility_trusted": String(accessibility.trusted),
                "accessibility_error": accessibility.error ?? "none",
                "accessibility_role": accessibility.focusedElement?.role ?? "",
                "accessibility_selected_chars": String(accessibility.focusedElement?.selectedText?.count ?? 0),
            ])
        } catch {
            DevLog.info("debug_capture_recording_event_append_failed", fields: [
                "capture_id": captureID,
                "run": runID,
                "error": error.localizedDescription,
            ])
        }
    }
}
