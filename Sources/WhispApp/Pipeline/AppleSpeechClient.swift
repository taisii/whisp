import Foundation
import Speech
import WhispCore

final class AppleSpeechClient: @unchecked Sendable {
    func transcribe(
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> (transcript: String, usage: STTUsage?) {
        let status = await resolveAuthorizationStatus()
        guard status == .authorized else {
            throw AppError.invalidArgument(authorizationErrorMessage(status))
        }

        let locale = localeForLanguage(language)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AppError.invalidArgument("Apple Speechが locale=\(locale.identifier) に対応していません")
        }
        guard recognizer.isAvailable else {
            throw AppError.io("Apple Speechが現在利用できません")
        }

        let normalizedSampleRate = max(sampleRate, 1)
        let wavData = buildWAVBytes(sampleRate: UInt32(normalizedSampleRate), pcmData: audio)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisp-apple-stt-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try wavData.write(to: tmpURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let request = SFSpeechURLRecognitionRequest(url: tmpURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true

        do {
            let transcript = try await recognizeTranscript(request: request, recognizer: recognizer)
            let duration = audio.isEmpty ? 0 : Double(audio.count) / Double(normalizedSampleRate * MemoryLayout<Int16>.size)
            let usage = duration > 0 ? STTUsage(durationSeconds: duration, requestID: nil) : nil
            return (transcript.trimmingCharacters(in: .whitespacesAndNewlines), usage)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.io("Apple Speech 文字起こしに失敗: \(error.localizedDescription)")
        }
    }

    private func recognizeTranscript(
        request: SFSpeechURLRecognitionRequest,
        recognizer: SFSpeechRecognizer
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    guard !finished else { return }
                    finished = true
                    task?.cancel()
                    task = nil
                    continuation.resume(throwing: error)
                    return
                }

                guard let result, result.isFinal else {
                    return
                }
                guard !finished else { return }
                finished = true
                task = nil
                let transcript = result.bestTranscription.formattedString
                continuation.resume(returning: transcript)
            }
        }
    }

    private func resolveAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined {
            return current
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func authorizationErrorMessage(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return "音声認識権限が未許可です（システム設定 > プライバシーとセキュリティ > 音声認識）"
        case .restricted:
            return "このMacでは音声認識が制限されています"
        case .notDetermined:
            return "音声認識権限の確認中です。再度お試しください"
        case .authorized:
            return ""
        @unknown default:
            return "音声認識権限の状態を判定できませんでした"
        }
    }

    private func localeForLanguage(_ language: String?) -> Locale {
        switch language {
        case "ja":
            return Locale(identifier: "ja-JP")
        case "en":
            return Locale(identifier: "en-US")
        case .some(let value):
            return Locale(identifier: value)
        case .none:
            return Locale.current
        }
    }
}
