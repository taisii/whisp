import Foundation

public struct HTTPJSONClient: Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func sendJSONRequest<T: Encodable>(
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

        guard (200 ..< 300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AppError.io("API request failed (\(http.statusCode)): \(bodyText)")
        }

        return data
    }
}
