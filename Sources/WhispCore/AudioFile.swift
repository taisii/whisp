import Foundation

public struct AudioData: Equatable, Sendable {
    public let sampleRate: UInt32
    public let pcmBytes: Data
    public let durationSeconds: Float

    public init(sampleRate: UInt32, pcmBytes: Data, durationSeconds: Float) {
        self.sampleRate = sampleRate
        self.pcmBytes = pcmBytes
        self.durationSeconds = durationSeconds
    }
}

public func buildWAVBytes(sampleRate: UInt32, pcmData: Data) -> Data {
    let numChannels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
    let blockAlign = numChannels * bitsPerSample / 8
    let dataSize = UInt32(pcmData.count)
    let fileSize = 36 + dataSize

    var wav = Data()
    wav.reserveCapacity(44 + pcmData.count)
    wav.append("RIFF".data(using: .ascii)!)
    wav.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian, Array.init))
    wav.append("WAVE".data(using: .ascii)!)
    wav.append("fmt ".data(using: .ascii)!)
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init))
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))
    wav.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian, Array.init))
    wav.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
    wav.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
    wav.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
    wav.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
    wav.append("data".data(using: .ascii)!)
    wav.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))
    wav.append(pcmData)

    return wav
}

public func parsePCM16MonoWAV(_ wavData: Data) throws -> AudioData {
    guard wavData.count >= 44 else {
        throw AppError.invalidArgument("WAVが短すぎます")
    }

    guard wavData.starts(with: Data("RIFF".utf8)),
          wavData[8..<12] == Data("WAVE".utf8)
    else {
        throw AppError.invalidArgument("WAVヘッダが不正です")
    }

    var cursor = 12
    var sampleRate: UInt32?
    var channels: UInt16?
    var bitsPerSample: UInt16?
    var pcmData: Data?

    while cursor + 8 <= wavData.count {
        let chunkID = wavData[cursor..<(cursor + 4)]
        let chunkSize = Int(readLEUInt32(wavData, offset: cursor + 4))
        let chunkDataStart = cursor + 8
        let chunkDataEnd = chunkDataStart + chunkSize

        if chunkDataEnd > wavData.count {
            break
        }

        if chunkID == Data("fmt ".utf8) {
            guard chunkSize >= 16 else {
                throw AppError.invalidArgument("fmtチャンクが不正です")
            }
            let format = readLEUInt16(wavData, offset: chunkDataStart)
            if format != 1 {
                throw AppError.invalidArgument("PCM以外のWAVは未対応です")
            }
            channels = readLEUInt16(wavData, offset: chunkDataStart + 2)
            sampleRate = readLEUInt32(wavData, offset: chunkDataStart + 4)
            bitsPerSample = readLEUInt16(wavData, offset: chunkDataStart + 14)
        } else if chunkID == Data("data".utf8) {
            pcmData = wavData.subdata(in: chunkDataStart..<chunkDataEnd)
        }

        cursor = chunkDataEnd + (chunkSize % 2)
    }

    guard let sr = sampleRate, let ch = channels, let bps = bitsPerSample, let pcm = pcmData else {
        throw AppError.invalidArgument("WAVのfmt/dataチャンクが見つかりません")
    }
    guard ch == 1 else {
        throw AppError.invalidArgument("モノラルWAVのみ対応です")
    }
    guard bps == 16 else {
        throw AppError.invalidArgument("16-bit PCM WAVのみ対応です")
    }

    let duration = pcm.count > 0 ? Float(pcm.count) / Float(sr * 2) : 0
    return AudioData(sampleRate: sr, pcmBytes: pcm, durationSeconds: duration)
}

private func readLEUInt16(_ data: Data, offset: Int) -> UInt16 {
    let value = data.withUnsafeBytes { raw in
        raw.load(fromByteOffset: offset, as: UInt16.self)
    }
    return UInt16(littleEndian: value)
}

private func readLEUInt32(_ data: Data, offset: Int) -> UInt32 {
    let value = data.withUnsafeBytes { raw in
        raw.load(fromByteOffset: offset, as: UInt32.self)
    }
    return UInt32(littleEndian: value)
}
