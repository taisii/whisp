import AVFoundation
import Foundation
import WhispCore

struct RecordingResult {
    let sampleRate: Int
    let pcmData: Data
}

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    private var pcmData = Data()
    private(set) var sampleRate: Int = 16_000
    private var isRecording = false

    func start() throws {
        guard !isRecording else { return }

        pcmData = Data()

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        sampleRate = Int(format.sampleRate)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
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

        lock.lock()
        let data = pcmData
        lock.unlock()

        return RecordingResult(sampleRate: sampleRate, pcmData: data)
    }

    private func append(buffer: AVAudioPCMBuffer) {
        var local = Data(capacity: Int(buffer.frameLength) * 2)

        if let floatChannels = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)

            for frame in 0..<frameLength {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += floatChannels[channel][frame]
                }
                let mono = sum / Float(max(channelCount, 1))
                append(i16: f32ToI16(mono), to: &local)
            }
        } else if let int16Channels = buffer.int16ChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)

            for frame in 0..<frameLength {
                var sum: Int32 = 0
                for channel in 0..<channelCount {
                    sum += Int32(int16Channels[channel][frame])
                }
                let mono = Int16(clamping: sum / Int32(max(channelCount, 1)))
                append(i16: mono, to: &local)
            }
        }

        guard !local.isEmpty else { return }

        lock.lock()
        pcmData.append(local)
        lock.unlock()
    }

    private func append(i16: Int16, to data: inout Data) {
        var value = i16.littleEndian
        withUnsafeBytes(of: &value) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
