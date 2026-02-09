import Foundation

public struct TranscriptChunk: Equatable, Sendable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public struct ParsedDeepgramMessage: Equatable, Sendable {
    public let chunk: TranscriptChunk
    public let duration: Double
    public let requestID: String?

    public init(chunk: TranscriptChunk, duration: Double, requestID: String?) {
        self.chunk = chunk
        self.duration = duration
        self.requestID = requestID
    }
}

private struct DeepgramMessage: Decodable {
    let channel: DeepgramChannel
    let isFinal: Bool
    let duration: Double
    let metadata: DeepgramMetadata?

    enum CodingKeys: String, CodingKey {
        case channel
        case isFinal = "is_final"
        case duration
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = try container.decode(DeepgramChannel.self, forKey: .channel)
        isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        metadata = try container.decodeIfPresent(DeepgramMetadata.self, forKey: .metadata)
    }
}

private struct DeepgramMetadata: Decodable {
    let duration: Double
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case duration
        case requestID = "request_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID) ?? ""
    }
}

private struct DeepgramChannel: Decodable {
    let alternatives: [DeepgramAlternative]
}

private struct DeepgramAlternative: Decodable {
    let transcript: String

    enum CodingKeys: String, CodingKey {
        case transcript
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript) ?? ""
    }
}

public func parseDeepgramMessage(_ text: String) -> TranscriptChunk? {
    guard let parsed = try? JSONDecoder().decode(DeepgramMessage.self, from: Data(text.utf8)),
          let alternative = parsed.channel.alternatives.first
    else {
        return nil
    }

    return TranscriptChunk(text: alternative.transcript, isFinal: parsed.isFinal)
}

public func parseDeepgramMessageWithDuration(_ text: String) -> ParsedDeepgramMessage? {
    guard let parsed = try? JSONDecoder().decode(DeepgramMessage.self, from: Data(text.utf8)),
          let alternative = parsed.channel.alternatives.first
    else {
        return nil
    }

    let metadataDuration = parsed.metadata?.duration ?? 0
    let duration = metadataDuration > 0 ? metadataDuration : parsed.duration
    let requestID: String?
    if let candidate = parsed.metadata?.requestID, !candidate.isEmpty {
        requestID = candidate
    } else {
        requestID = nil
    }

    return ParsedDeepgramMessage(
        chunk: TranscriptChunk(text: alternative.transcript, isFinal: parsed.isFinal),
        duration: duration,
        requestID: requestID
    )
}
