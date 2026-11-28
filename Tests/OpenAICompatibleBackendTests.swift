import Foundation
import UIKit
import XCTest
@testable import AmoreChatStandalone

/// In-process URLProtocol exercises the real URLSession.bytes(for:) transport; no production mocks.
private final class StreamingURLProtocol: URLProtocol {
    static var status = 200
    static var contentType = "text/event-stream"
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
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": Self.contentType])!
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
        StreamingURLProtocol.contentType = "text/event-stream"
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
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.first?["content"] as? String, BuiltInPersona.instruction)
        XCTAssertEqual(messages[2]["content"] as? String, "previous")
        XCTAssertNil(messages[2]["reasoning"])
        XCTAssertNil(messages[2]["reasoning_content"])
    }

    func testPersonaPreservesTopicQueryAndExistingPlayContext() throws {
        let topic = [ChatMessage(role: .user, content: "剧情游戏")]
        let play = [ChatMessage(role: .user, content: "请主持一段很短的文字冒险。"),
                    ChatMessage(role: .assistant, content: "你想玩哪种题材？"),
                    ChatMessage(role: .user, content: "悬疑")]
        let adapter = backend(profile(.deepSeek, appendV1: false))
        for conversation in [topic, play] {
            let request = try adapter.requestBody(messages: conversation, options: plain)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
            let sent = try XCTUnwrap(body["messages"] as? [[String: String]])
            let expected = [["role": "system", "content": BuiltInPersona.instruction]] + conversation.map {
                ["role": $0.role.rawValue, "content": $0.content]
            }
            XCTAssertEqual(sent, expected)
        }
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

    func testDeepSeekThinkingSwitchAndVerifiedSearchEndpoint() throws {
        let deepSeek = backend(profile(.deepSeek, appendV1: false))
        for enabled in [false, true] {
            let body = try deepSeek.requestBody(messages: history,
                options: ChatOptions(deepThinking: enabled, webSearch: false))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual((json["thinking"] as? [String: String])?["type"], enabled ? "enabled" : "disabled")
            XCTAssertNil(json["plugins"])
        }
        XCTAssertTrue(profile().allowsWebSearch)
        XCTAssertFalse(profile(.deepSeek).allowsWebSearch)
        XCTAssertFalse(profile(.openRouter, base: "https://example.com/api").allowsWebSearch)
        XCTAssertFalse(profile(.openRouter, base: "https://openrouter.ai/other").allowsWebSearch)
        XCTAssertFalse(profile(.deepSeek, base: "https://example.com").allowsThinking)
    }

    func testCustomModelOnlySendsExplicitlyConfiguredOptions() throws {
        var custom = profile(.custom, base: "https://example.com/v1", appendV1: false)
        let options = ChatOptions(deepThinking: true, webSearch: true)
        func payload(_ profile: ModelProfile) throws -> [String: Any] {
            let body = try backend(profile).requestBody(messages: history, options: options)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        XCTAssertNil(try payload(custom)["plugins"])
        XCTAssertNil(try payload(custom)["thinking"])
        custom.compatibleThinking = .deepSeekSwitch
        custom.compatibleWebSearch = true
        let json = try payload(custom)
        XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual((json["plugins"] as? [[String: String]])?.first?["id"], "web")
        XCTAssertTrue(custom.allowsThinking && custom.allowsWebSearch)
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
        let text = try XCTUnwrap(list.last?["content"] as? String)
        XCTAssertTrue(text.contains("Sample PDF body"))
    }

    func testSkipsEmptyFailedRepliesButPreservesPartialAnswersAndSourceHistory() throws {
        let conversation = [ChatMessage(role: .user, content: "first"),
            ChatMessage(role: .assistant, content: "", reasoning: "private thought", status: .failed),
            ChatMessage(role: .user, content: "second"),
            ChatMessage(role: .assistant, content: "partial answer", status: .failed),
            ChatMessage(role: .user, content: "third")]
        let body = try backend(profile()).requestBody(messages: conversation, options: plain)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(sent.map { $0["role"] }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(sent[1]["content"], "first\n\nsecond")
        XCTAssertEqual(sent[2]["content"], "partial answer")
        XCTAssertEqual(sent[3]["content"], "third")
        XCTAssertEqual(conversation.count, 5)
        XCTAssertEqual(conversation[1].reasoning, "private thought")
        XCTAssertEqual(conversation[1].status, .failed)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("private thought"))
    }

    func testEmptyOnlyConversationFailsWithoutNetworkOrSyntheticAnswer() async {
        do {
            _ = try await backend(profile()).stream(messages: [ChatMessage(role: .assistant,
                content: "  \n", reasoning: "private thought", status: .failed)], options: plain)
            XCTFail("No usable user/assistant content must not synthesize a response")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertNil(StreamingURLProtocol.capturedRequest)
    }

    func testJSONBusyErrorsKeepSafeStatusAndNeverExposeBody() async throws {
        StreamingURLProtocol.contentType = "application/json"
        for status in [429, 500] {
            StreamingURLProtocol.status = status
            StreamingURLProtocol.lines = [Data("{\"code\":\"UPSTREAM_BUSY\",\"message\":\"fixture-fake-secret private prompt https://private.invalid\"}".utf8)]
            let stream = try await backend(profile()).stream(messages: history, options: plain)
            do {
                for try await _ in stream {}
                XCTFail("JSON error must not complete as an empty successful SSE")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("HTTP \(status)"))
                XCTAssertTrue(error.localizedDescription.contains("繁忙"))
                XCTAssertFalse(error.localizedDescription.contains("fixture-fake-secret"))
                XCTAssertFalse(error.localizedDescription.contains("private prompt"))
                XCTAssertFalse(error.localizedDescription.contains("private.invalid"))
            }
            XCTAssertEqual(StreamingURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Accept"),
                           "text/event-stream, application/json")
        }
    }

    func testUnknownJSONCodeCannotLeakArbitraryServerText() async throws {
        StreamingURLProtocol.contentType = "application/json"
        StreamingURLProtocol.status = 502
        StreamingURLProtocol.lines = [Data("{\"code\":\"private-account-secret\",\"message\":\"private prompt\"}".utf8)]
        let stream = try await backend(profile()).stream(messages: history, options: plain)
        do {
            for try await _ in stream {}
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("502"))
            XCTAssertFalse(error.localizedDescription.contains("private"))
        }
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
