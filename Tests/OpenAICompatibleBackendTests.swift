import Foundation
import UIKit
import XCTest
@testable import AmoreChatStandalone

/// In-process URLProtocol exercises the real URLSession.bytes(for:) transport; no production mocks.
private final class StreamingURLProtocol: URLProtocol {
    static var status = 200
    static var lines: [Data] = []
    static var capturedRequest: URLRequest?
    static var startExpectation: XCTestExpectation?
    static var holdOpen = false
    static var stopExpectation: XCTestExpectation?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Self.startExpectation?.fulfill()
        for line in Self.lines { client?.urlProtocol(self, didLoad: line) }
        if !Self.holdOpen { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() { Self.stopExpectation?.fulfill() }
}

final class OpenAICompatibleBackendTests: XCTestCase {
    private func profile(_ provider: ModelProvider = .openRouter, base: String? = nil,
                         appendV1: Bool = true) -> ModelProfile {
        ModelProfile(label: "Fixture", provider: provider,
                     baseURL: base ?? provider.defaultBaseURL,
                     modelID: "fixture-model", appendV1: appendV1)
    }

    private func backend(_ profile: ModelProfile) -> OpenAICompatibleBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingURLProtocol.self]
        return OpenAICompatibleBackend(profile: profile, apiKey: "fixture-fake-secret",
                                       session: URLSession(configuration: configuration))
    }

    private let history = [ChatMessage(role: .user, content: "hello"),
                           ChatMessage(role: .assistant, content: "previous", reasoning: "thinking"),
                           ChatMessage(role: .user, content: "again")]
    private let plain = ChatOptions(deepThinking: false, webSearch: false)

    override func setUp() {
        super.setUp()
        StreamingURLProtocol.status = 200
        StreamingURLProtocol.lines = []
        StreamingURLProtocol.capturedRequest = nil
        StreamingURLProtocol.startExpectation = nil
        StreamingURLProtocol.stopExpectation = nil
        StreamingURLProtocol.holdOpen = false
    }

    func testSplitSSEWithReasoningAndMultiturnContext() async throws {
        // Deliberately split the UTF-8 event data across URLProtocol deliveries.
        let fixture = "data: {\"choices\":[{\"delta\":{\"reasoning\":\"思考\",\"content\":\"答案\"}}]}\r\n\r\ndata: [DONE]\r\n\r\n"
        let raw = Data(fixture.utf8)
        StreamingURLProtocol.lines = [Data(bytes: raw.prefix(10)), Data(bytes: raw.dropFirst(10).prefix(17)),
                                      Data(bytes: raw.dropFirst(27))]
        let stream = try await backend(profile()).stream(messages: history,
            options: ChatOptions(deepThinking: true, webSearch: true))
        var reasoning = "", text = ""
        for try await chunk in stream {
            switch chunk {
            case .reasoning(let value): reasoning += value
            case .text(let value): text += value
            }
        }
        XCTAssertEqual(reasoning, "思考")
        XCTAssertEqual(text, "答案")
        let request = try XCTUnwrap(StreamingURLProtocol.capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-fake-secret")
        let body = try backend(profile()).requestBody(messages: history,
            options: ChatOptions(deepThinking: true, webSearch: true))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "fixture-model")
        XCTAssertEqual((json["reasoning"] as? [String: Bool])?["enabled"], true)
        XCTAssertEqual(((json["plugins"] as? [[String: String]])?.first)?["id"], "web")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[1]["content"] as? String, "previous")
        XCTAssertEqual(messages[1]["reasoning"] as? String, "thinking")
    }

    func testRejectsInvalidURLAndUnsupportedSearchBeforeNetwork() async throws {
        for base in ["http://example.com", "https://user:pass@example.com/v1",
                     "https://example.com/v1/v1", "https://example.com/v1/chat/completions"] {
            do {
                _ = try await backend(profile(.custom, base: base)).stream(messages: history, options: plain)
                XCTFail("Expected invalid URL")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        do {
            _ = try await backend(profile(.openAI)).stream(messages: history,
                options: ChatOptions(deepThinking: false, webSearch: true))
            XCTFail("Search on OpenAI must fail closed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("OpenRouter")) }
        XCTAssertNil(StreamingURLProtocol.capturedRequest)
    }

    func testErrorBodyNeverAppearsInUserFacingMessage() async throws {
        StreamingURLProtocol.status = 401
        StreamingURLProtocol.lines = [Data("fixture-fake-secret server detail".utf8)]
        let stream = try await backend(profile()).stream(messages: history, options: plain)
        do {
            for try await _ in stream {}
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains("fixture-fake-secret"))
            XCTAssertFalse(error.localizedDescription.contains("server detail"))
        }
    }

    func testMissingDoneIsAnErrorNotSuccessfulCompletion() async throws {
        StreamingURLProtocol.lines = [Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n".utf8)]
        let stream = try await backend(profile()).stream(messages: history, options: plain)
        var text = ""
        do {
            for try await chunk in stream {
                if case .text(let value) = chunk { text += value }
            }
            XCTFail("Truncated SSE must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("中断")) }
        XCTAssertEqual(text, "partial")
    }

    func testUnsupportedBinaryFileFailsBeforeRequest() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0, 1, 2]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let attachment = ChatAttachment(name: "archive.zip", localURL: url, type: "application/zip")
        do {
            _ = try await backend(profile()).stream(messages: [ChatMessage(role: .user,
                content: "check", attachments: [attachment])], options: plain)
            XCTFail("Unsupported binary should not be sent")
        } catch { XCTAssertTrue(error.localizedDescription.contains("附件")) }
        XCTAssertNil(StreamingURLProtocol.capturedRequest)
    }

    func testExtractsLocalPDFTextIntoActualRequest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        let pdf = renderer.pdfData { context in
            context.beginPage()
            ("Sample PDF body" as NSString).draw(at: CGPoint(x: 20, y: 20),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        try pdf.write(to: url)
        let attachment = ChatAttachment(name: "sample.pdf", localURL: url, type: "application/pdf")
        let body = try backend(profile()).requestBody(messages: [ChatMessage(role: .user,
            content: "Please summarize", attachments: [attachment])], options: plain)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let list = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let text = try XCTUnwrap(list.first?["content"] as? String)
        XCTAssertTrue(text.contains("Sample PDF body"))
    }

    func testCancellingConsumerStopsURLSessionRequest() async throws {
        StreamingURLProtocol.holdOpen = true
        let started = expectation(description: "Request started")
        let stopped = expectation(description: "URLSession request cancelled")
        StreamingURLProtocol.startExpectation = started
        StreamingURLProtocol.stopExpectation = stopped
        let stream = try await backend(profile()).stream(messages: history, options: plain)
        let reader = Task {
            for try await _ in stream {}
        }
        await fulfillment(of: [started], timeout: 5)
        reader.cancel()
        await fulfillment(of: [stopped], timeout: 5)
        // AsyncThrowingStream may terminate normally when the consumer task is
        // cancelled. The transport cancellation above is the invariant; the
        // controller independently checks Task.checkCancellation before success.
        do { try await reader.value }
        catch is CancellationError { /* also permitted */ }
        catch { XCTFail("Expected cancellation, got \(type(of: error))") }
    }
}
