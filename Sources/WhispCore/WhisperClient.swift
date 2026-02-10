import Foundation

private struct WhisperTranscriptionResponse: Decodable {
    let text: String
}

public actor WhisperClient {
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
        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw AppError.invalidArgument("Whisper URL生成に失敗")
        }

        let normalizedSampleRate = max(sampleRate, 1)
        let wavData = buildWAVBytes(sampleRate: UInt32(normalizedSampleRate), pcmData: audio)
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = makeMultipartBody(
            boundary: boundary,
            fields: [
                ("model", "whisper-1"),
                ("response_format", "json"),
                language.map { ("language", $0) },
            ].compactMap { $0 },
            fileFieldName: "file",
            fileName: "audio.wav",
            mimeType: "audio/wav",
            fileData: wavData
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.io("Whisper HTTPレスポンスが不正です")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AppError.io("Whisper request failed (\(http.statusCode)): \(bodyText)")
        }

        let decoded = try JSONDecoder().decode(WhisperTranscriptionResponse.self, from: data)
        let duration = audio.isEmpty ? 0 : Double(audio.count) / Double(normalizedSampleRate * MemoryLayout<Int16>.size)
        let requestID = http.value(forHTTPHeaderField: "x-request-id")
        let usage = duration > 0
            ? STTUsage(
                durationSeconds: duration,
                requestID: requestID,
                provider: STTProvider.whisper.rawValue
            )
            : nil

        return (decoded.text.trimmingCharacters(in: .whitespacesAndNewlines), usage)
    }

    private func makeMultipartBody(
        boundary: String,
        fields: [(String, String)],
        fileFieldName: String,
        fileName: String,
        mimeType: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        for (name, value) in fields {
            body.appendUTF8("--\(boundary)\(lineBreak)")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)")
            body.appendUTF8("\(value)\(lineBreak)")
        }

        body.appendUTF8("--\(boundary)\(lineBreak)")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\(lineBreak)")
        body.appendUTF8("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
        body.append(fileData)
        body.appendUTF8(lineBreak)
        body.appendUTF8("--\(boundary)--\(lineBreak)")
        return body
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
