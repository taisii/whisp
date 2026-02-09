import Foundation

public func f32ToI16(_ sample: Float) -> Int16 {
    let clamped = min(max(sample, -1.0), 1.0)
    return Int16(clamped * Float(Int16.max))
}

public func u16ToI16(_ sample: UInt16) -> Int16 {
    Int16(truncatingIfNeeded: Int32(sample) - 32768)
}

public func downmixF32(_ data: [Float], channels: Int) -> [Float] {
    guard channels > 1 else { return data }
    var output: [Float] = []
    output.reserveCapacity(data.count / channels)

    var index = 0
    while index < data.count {
        let end = min(index + channels, data.count)
        let frame = data[index..<end]
        let sum = frame.reduce(0, +)
        output.append(sum / Float(frame.count))
        index += channels
    }
    return output
}

public func downmixI16(_ data: [Int16], channels: Int) -> [Int16] {
    guard channels > 1 else { return data }
    var output: [Int16] = []
    output.reserveCapacity(data.count / channels)

    var index = 0
    while index < data.count {
        let end = min(index + channels, data.count)
        let frame = data[index..<end]
        let sum = frame.reduce(0) { $0 + Int32($1) }
        let avg = sum / Int32(frame.count)
        output.append(Int16(clamping: avg))
        index += channels
    }
    return output
}

public func downmixU16(_ data: [UInt16], channels: Int) -> [UInt16] {
    guard channels > 1 else { return data }
    var output: [UInt16] = []
    output.reserveCapacity(data.count / channels)

    var index = 0
    while index < data.count {
        let end = min(index + channels, data.count)
        let frame = data[index..<end]
        let sum = frame.reduce(0) { $0 + UInt32($1) }
        output.append(UInt16(sum / UInt32(frame.count)))
        index += channels
    }
    return output
}
