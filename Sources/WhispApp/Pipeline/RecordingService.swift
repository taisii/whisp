import Foundation

protocol RecordingService: Sendable {
    func startRecording(onChunk: @escaping (Data) -> Void) throws -> AudioRecorder
    func stopRecording(_ recorder: AudioRecorder) -> RecordingResult
}

struct SystemRecordingService: RecordingService {
    func startRecording(onChunk: @escaping (Data) -> Void) throws -> AudioRecorder {
        let recorder = AudioRecorder(onChunk: onChunk)
        try recorder.start()
        return recorder
    }

    func stopRecording(_ recorder: AudioRecorder) -> RecordingResult {
        recorder.stop()
    }
}
