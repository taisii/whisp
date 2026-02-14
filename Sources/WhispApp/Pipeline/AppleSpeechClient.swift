import AVFoundation
import Foundation
import Speech
import WhispCore

final class AppleSpeechClient: @unchecked Sendable {
    private let streamingLock = NSLock()
    private var streamingState: AppleSpeechStreamingState?

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
            let usage = duration > 0
                ? STTUsage(
                    durationSeconds: duration,
                    requestID: nil,
                    provider: STTProvider.appleSpeech.rawValue
                )
                : nil
            return (transcript.trimmingCharacters(in: .whitespacesAndNewlines), usage)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.io("Apple Speech 文字起こしに失敗: \(error.localizedDescription)")
        }
    }

    func startStreaming(
        sampleRate: Int,
        language: String?
    ) async throws {
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
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        let state = AppleSpeechStreamingState(sampleRate: normalizedSampleRate)
        let task = recognizer.recognitionTask(with: request) { result, error in
            state.handleRecognitionResult(result: result, error: error)
        }
        state.activate(request: request, task: task, recognizer: recognizer)

        let previousState = replaceStreamingState(with: state)
        previousState?.cancel()
    }

    func enqueueStreamingAudioChunk(_ chunk: Data) async {
        guard !chunk.isEmpty else {
            return
        }
        currentStreamingState()?.appendAudioChunk(chunk)
    }

    func finishStreaming() async throws -> (transcript: String, usage: STTUsage?) {
        guard let state = currentStreamingState() else {
            throw AppError.invalidArgument("Apple Speech streaming セッションが開始されていません")
        }

        defer { clearStreamingState(state) }
        do {
            let transcript = try await state.finish()
            let usage: STTUsage?
            let durationSeconds = state.durationSeconds
            if durationSeconds > 0 {
                usage = STTUsage(
                    durationSeconds: durationSeconds,
                    requestID: nil,
                    provider: STTProvider.appleSpeech.rawValue
                )
            } else {
                usage = nil
            }
            return (transcript.trimmingCharacters(in: .whitespacesAndNewlines), usage)
        } catch let appError as AppError {
            throw appError
        } catch {
            throw AppError.io("Apple Speech ストリーミング認識に失敗: \(error.localizedDescription)")
        }
    }

    private func currentStreamingState() -> AppleSpeechStreamingState? {
        streamingLock.lock()
        let state = streamingState
        streamingLock.unlock()
        return state
    }

    private func clearStreamingState(_ state: AppleSpeechStreamingState) {
        let shouldClear: Bool
        streamingLock.lock()
        shouldClear = streamingState === state
        if shouldClear {
            streamingState = nil
        }
        streamingLock.unlock()
        if shouldClear {
            state.cancel()
        }
    }

    private func replaceStreamingState(with state: AppleSpeechStreamingState) -> AppleSpeechStreamingState? {
        streamingLock.lock()
        let previous = streamingState
        streamingState = state
        streamingLock.unlock()
        return previous
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

private final class AppleSpeechStreamingState: @unchecked Sendable {
    private let lock = NSLock()
    private let sampleRate: Int

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var completed = false
    private var latestTranscript = ""
    private var terminalError: Error?
    private var totalAudioBytes = 0

    init(sampleRate: Int) {
        self.sampleRate = max(sampleRate, 1)
    }

    var durationSeconds: Double {
        lock.lock()
        let bytes = totalAudioBytes
        lock.unlock()
        let denominator = Double(sampleRate * MemoryLayout<Int16>.size)
        guard denominator > 0 else {
            return 0
        }
        return Double(bytes) / denominator
    }

    func activate(
        request: SFSpeechAudioBufferRecognitionRequest,
        task: SFSpeechRecognitionTask,
        recognizer: SFSpeechRecognizer
    ) {
        lock.lock()
        self.request = request
        self.task = task
        self.recognizer = recognizer
        lock.unlock()
    }

    func appendAudioChunk(_ chunk: Data) {
        guard !chunk.isEmpty else {
            return
        }

        let request: SFSpeechAudioBufferRecognitionRequest?
        let sampleRate = self.sampleRate
        lock.lock()
        let canAppend = !completed && terminalError == nil
        if canAppend {
            totalAudioBytes += chunk.count
            request = self.request
        } else {
            request = nil
        }
        lock.unlock()

        guard canAppend, let request else {
            return
        }

        guard let buffer = makePCMBuffer(from: chunk, sampleRate: sampleRate) else {
            setTerminalError(AppError.encode("Apple Speech streaming chunk の変換に失敗しました"))
            return
        }
        request.append(buffer)
    }

    func finish(timeoutNanoseconds: UInt64 = 8_000_000_000) async throws -> String {
        endAudio()
        let started = DispatchTime.now().uptimeNanoseconds
        while true {
            let snapshot = stateSnapshot()
            if let error = snapshot.error {
                throw error
            }
            if snapshot.completed {
                return snapshot.transcript
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - started >= timeoutNanoseconds {
                if snapshot.transcript.isEmpty {
                    throw AppError.io("Apple Speech ストリーミング最終結果の待機がタイムアウトしました")
                }
                return snapshot.transcript
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func cancel() {
        let task: SFSpeechRecognitionTask?
        let request: SFSpeechAudioBufferRecognitionRequest?
        lock.lock()
        task = self.task
        request = self.request
        self.task = nil
        self.request = nil
        recognizer = nil
        completed = true
        lock.unlock()
        request?.endAudio()
        task?.cancel()
    }

    func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            setTerminalError(error)
            return
        }
        guard let result else {
            return
        }

        let transcript = result.bestTranscription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if !transcript.isEmpty {
            latestTranscript = transcript
        }
        let isFinal = result.isFinal
        if isFinal {
            completed = true
            request = nil
            task = nil
            recognizer = nil
        }
        lock.unlock()
    }

    private func setTerminalError(_ error: Error) {
        let task: SFSpeechRecognitionTask?
        lock.lock()
        terminalError = error
        completed = true
        task = self.task
        self.task = nil
        request = nil
        recognizer = nil
        lock.unlock()
        task?.cancel()
    }

    private func stateSnapshot() -> (completed: Bool, transcript: String, error: Error?) {
        lock.lock()
        let snapshot = (completed: completed, transcript: latestTranscript, error: terminalError)
        lock.unlock()
        return snapshot
    }

    private func endAudio() {
        let request: SFSpeechAudioBufferRecognitionRequest?
        lock.lock()
        request = self.request
        lock.unlock()
        request?.endAudio()
    }

    private func makePCMBuffer(from chunk: Data, sampleRate: Int) -> AVAudioPCMBuffer? {
        guard !chunk.isEmpty else {
            return nil
        }
        let usableBytes = chunk.count - (chunk.count % MemoryLayout<Int16>.size)
        guard usableBytes > 0 else {
            return nil
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(usableBytes / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.int16ChannelData?.pointee
        else {
            return nil
        }
        buffer.frameLength = frameCount
        chunk.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            memcpy(channel, base, usableBytes)
        }
        return buffer
    }
}
