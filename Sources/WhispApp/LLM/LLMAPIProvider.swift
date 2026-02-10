import Foundation
import WhispCore

protocol LLMAPIProvider: Sendable {
    func supports(model: LLMModel) -> Bool

    func postProcess(
        apiKey: String,
        model: LLMModel,
        prompt: String
    ) async throws -> PostProcessResult

    func transcribeAudio(
        apiKey: String,
        model: LLMModel,
        prompt: String,
        wavData: Data,
        mimeType: String
    ) async throws -> PostProcessResult

    func analyzeVisionContext(
        apiKey: String,
        model: LLMModel,
        prompt: String,
        imageData: Data,
        mimeType: String
    ) async throws -> VisionContext?
}

struct HTTPJSONClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func sendJSONRequest<T: Encodable>(
        url: URL,
        method: String,
        headers: [String: String],
        body: T
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.io("HTTPレスポンスが不正")
        }

        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AppError.invalidArgument("API error: \(http.statusCode) \(bodyText)")
        }

        return data
    }
}
