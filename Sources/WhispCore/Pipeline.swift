import Foundation

public func isEmptySTT(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

public func collectAudio(_ chunks: [[UInt8]]) -> [UInt8] {
    var output: [UInt8] = []
    for chunk in chunks {
        output.append(contentsOf: chunk)
    }
    return output
}
