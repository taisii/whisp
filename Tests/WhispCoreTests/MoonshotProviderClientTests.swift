import Foundation
import XCTest
@testable import WhispCore

final class MoonshotProviderClientTests: XCTestCase {
    func testSendTextBuildsOpenAICompatiblePayload() async throws {
        let recorder = HTTPRequestRecorder()
        let provider = MoonshotProviderClient(client: HTTPJSONClient(session: recorder.session))
        recorder.nextResponseData = Data(
            """
            {
              "choices": [{"message": {"content": "ok"}}],
              "usage": {"prompt_tokens": 3, "completion_tokens": 4}
            }
            """.utf8
        )

        let response = try await provider.send(request: LLMRequest(
            model: .kimiK25,
            apiKey: "ms-key",
            payload: .text(prompt: "judge prompt")
        ))

        XCTAssertEqual(response.text, "ok")
        XCTAssertEqual(response.usage?.provider, "moonshot")

        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.moonshot.cn/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ms-key")

        let bodyString = String(data: try XCTUnwrap(readRequestBody(request)), encoding: .utf8) ?? ""
        let normalizedBodyString = bodyString.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(normalizedBodyString.contains("\"model\":\"kimi-k2.5\""))
        XCTAssertTrue(normalizedBodyString.contains("\"content\":\"judge prompt\""))
    }

    func testSendTextWithImageBuildsImageURLPayload() async throws {
        let recorder = HTTPRequestRecorder()
        let provider = MoonshotProviderClient(client: HTTPJSONClient(session: recorder.session))
        recorder.nextResponseData = Data(
            """
            {
              "choices": [{"message": {"content": "ok"}}],
              "usage": {"prompt_tokens": 5, "completion_tokens": 6}
            }
            """.utf8
        )

        let image = LLMRequestImage(mimeType: "image/png", base64Data: "AAAA")
        let response = try await provider.send(request: LLMRequest(
            model: .kimiK25,
            apiKey: "ms-key",
            payload: .textWithImage(prompt: "judge prompt", image: image)
        ))

        XCTAssertEqual(response.text, "ok")

        let request = try XCTUnwrap(recorder.lastRequest)
        let bodyString = String(data: try XCTUnwrap(readRequestBody(request)), encoding: .utf8) ?? ""
        let normalizedBodyString = bodyString.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(normalizedBodyString.contains("\"image_url\""), normalizedBodyString)
        XCTAssertTrue(normalizedBodyString.contains("\"judge prompt\""), normalizedBodyString)
        XCTAssertTrue(normalizedBodyString.contains("data:image/png;base64,AAAA"), normalizedBodyString)
    }

    private func readRequestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            if bytesRead <= 0 {
                break
            }
            data.append(buffer, count: bytesRead)
        }
        return data.isEmpty ? nil : data
    }
}

private final class HTTPRequestRecorder {
    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var owner: HTTPRequestRecorder?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let owner = Self.owner else {
                client?.urlProtocol(self, didFailWithError: NSError(domain: "HTTPRequestRecorder", code: -1))
                return
            }
            owner.lastRequest = request

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.moonshot.cn/v1/chat/completions")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: owner.nextResponseData)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private(set) var lastRequest: URLRequest?
    var nextResponseData: Data = Data("{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}".utf8)

    let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        StubURLProtocol.owner = self
    }
}
