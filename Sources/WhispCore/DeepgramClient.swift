import Foundation

private struct DeepgramListenResponse: Decodable {
    struct Metadata: Decodable {
        let duration: Double?
        let requestID: String?

        enum CodingKeys: String, CodingKey {
            case duration
            case requestID = "request_id"
        }
    }

    struct Results: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable {
                let transcript: String
            }

            let alternatives: [Alternative]
        }

        let channels: [Channel]
    }

    let metadata: Metadata?
    let results: Results?
}

public actor DeepgramClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func transcribe(
        apiKey: String,
        sampleRate: Int,
        audio: Data,
        language: String?
    ) async throws -> (transcript: String, usage: STTUsage?) {
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var items = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "punctuate", value: "false"),
        ]
        if let language {
            items.append(URLQueryItem(name: "language", value: language))
        }
        components.queryItems = items

        guard let url = components.url else {
            throw AppError.invalidArgument("Deepgram URL生成に失敗")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = audio
        request.addValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("audio/raw", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.io("Deepgramレスポンスが不正です")
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AppError.io("Deepgram request failed (\(http.statusCode)): \(body)")
        }

        let decoded = try JSONDecoder().decode(DeepgramListenResponse.self, from: data)
        let transcript = decoded.results?.channels.first?.alternatives.first?.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let usage: STTUsage?
        if let duration = decoded.metadata?.duration, duration > 0 {
            usage = STTUsage(
                durationSeconds: duration,
                requestID: decoded.metadata?.requestID,
                provider: STTProvider.deepgram.rawValue
            )
        } else {
            usage = nil
        }

        return (transcript, usage)
    }
}
