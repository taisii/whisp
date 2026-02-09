@preconcurrency import AVFoundation
import Foundation
import WhispCore

struct RecordingResult {
    let sampleRate: Int
    let pcmData: Data
}

private struct UnsafeSendablePCMBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer
}

private final class ConversionState: @unchecked Sendable {
    var didSendInput = false
}

final class AudioRecorder {
    static let targetSampleRate = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let onChunk: (Data) -> Void

    private var pcmData = Data()
    private(set) var sampleRate: Int = AudioRecorder.targetSampleRate
    private var isRecording = false
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    init(onChunk: @escaping (Data) -> Void = { _ in }) {
        self.onChunk = onChunk
    }

    func start() throws {
        guard !isRecording else { return }

        pcmData = Data()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(Self.targetSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AppError.invalidArgument("録音フォーマット初期化に失敗")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AppError.invalidArgument("音声コンバータ初期化に失敗")
        }

        self.outputFormat = outputFormat
        self.converter = converter
        sampleRate = Self.targetSampleRate

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() -> RecordingResult {
        guard isRecording else {
            return RecordingResult(sampleRate: sampleRate, pcmData: Data())
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        let flushedBytes = flushConverterTail()
        converter = nil
        outputFormat = nil

        lock.lock()
        let data = pcmData
        lock.unlock()

        SystemLog.audio("recording_stop", fields: [
            "sample_rate": String(sampleRate),
            "pcm_bytes": String(data.count),
            "flushed_bytes": String(flushedBytes),
        ])

        return RecordingResult(sampleRate: sampleRate, pcmData: data)
    }

    private func append(buffer: AVAudioPCMBuffer) {
        guard let outputFormat else {
            return
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let estimatedFrames = max(AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16, 32)
        let state = ConversionState()
        let sendableBuffer = UnsafeSendablePCMBuffer(value: buffer)
        var emptyOutputStreak = 0

        while let converter {
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: estimatedFrames) else {
                return
            }

            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                if state.didSendInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                state.didSendInput = true
                outStatus.pointee = .haveData
                return sendableBuffer.value
            }

            if error != nil || status == .error {
                return
            }

            let wrote = appendConvertedBuffer(converted)
            emptyOutputStreak = wrote == 0 ? (emptyOutputStreak + 1) : 0

            switch status {
            case .haveData:
                if emptyOutputStreak >= 2 {
                    return
                }
            case .inputRanDry, .endOfStream:
                if wrote == 0 {
                    return
                }
            case .error:
                return
            @unknown default:
                return
            }
        }
    }

    private func flushConverterTail() -> Int {
        guard let outputFormat else {
            return 0
        }

        let state = ConversionState()
        var totalBytes = 0
        var emptyOutputStreak = 0

        while let converter {
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024) else {
                return totalBytes
            }

            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                if state.didSendInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                state.didSendInput = true
                outStatus.pointee = .endOfStream
                return nil
            }
            if error != nil || status == .error {
                return totalBytes
            }

            let wrote = appendConvertedBuffer(converted)
            totalBytes += wrote

            if wrote == 0 {
                emptyOutputStreak += 1
            } else {
                emptyOutputStreak = 0
            }

            switch status {
            case .haveData:
                if emptyOutputStreak >= 2 {
                    return totalBytes
                }
            case .inputRanDry, .endOfStream:
                if wrote == 0 {
                    return totalBytes
                }
            case .error:
                return totalBytes
            @unknown default:
                return totalBytes
            }
        }

        return totalBytes
    }

    private func appendConvertedBuffer(_ converted: AVAudioPCMBuffer) -> Int {
        guard converted.frameLength > 0 else {
            return 0
        }
        guard let channel = converted.int16ChannelData?[0] else {
            return 0
        }

        let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
        let local = Data(bytes: channel, count: byteCount)
        guard !local.isEmpty else {
            return 0
        }

        lock.lock()
        pcmData.append(local)
        lock.unlock()
        onChunk(local)
        return local.count
    }
}
