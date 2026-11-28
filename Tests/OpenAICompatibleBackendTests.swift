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
    static var transportError: URLError?
    static var deferErrorUntilChunk = false
    static var failAfterChunk: (() -> Void)?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": Self.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Self.startExpectation?.fulfill()
        if Self.deferErrorUntilChunk, let error = Self.transportError {
            let runLoop = RunLoop.current
            Self.failAfterChunk = { [weak self] in
                runLoop.perform {
                    guard let self = self, !self.stopped else { return }
                    self.client?.urlProtocol(self, didFailWithError: error)
                }
            }
        }
        for line in Self.lines { client?.urlProtocol(self, didLoad: line) }
        if let error = Self.transportError {
            if !Self.deferErrorUntilChunk {
                RunLoop.current.perform { [weak self] in
                    guard let self = self, !self.stopped else { return }
                    self.client?.urlProtocol(self, didFailWithError: error)
                }
            }
        } else if !Self.holdOpen {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped = true
        Self.stopExpectation?.fulfill()
    }
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
        StreamingURLProtocol.transportError = nil
        StreamingURLProtocol.deferErrorUntilChunk = false
        StreamingURLProtocol.failAfterChunk = nil
    }

    private func receiveFixture() async throws -> (text: String, reasoning: String, error: Error?) {
        let stream = try await backend(profile()).stream(messages: history, options: plain)
        var text = "", reasoning = ""
        do {
            for try await chunk in stream {
                switch chunk {
                case .text(let value): text += value
                case .reasoning(let value): reasoning += value
                }
                if let fail = StreamingURLProtocol.failAfterChunk {
                    StreamingURLProtocol.failAfterChunk = nil
                    fail()
                }
            }
            return (text, reasoning, nil)
        } catch { return (text, reasoning, error) }
    }

    private func failureReason(_ error: Error?) -> MessageFailureReason? {
        (error as? ChatFailureClassifying)?.failureReason
    }

    private func fragmented(_ text: String, size: Int) -> [Data] {
        let data = Data(text.utf8)
        return stride(from: 0, to: data.count, by: size).map {
            Data(data.dropFirst($0).prefix(size))
        }
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

    // OpenAI Chat Completions: stop is a normal terminal; length/content_filter/
    // tool_calls are not. WHATWG SSE defines BOM, CR/LF, and multiline data.
    // EOF tail dispatch below is a gateway compatibility extension, not a
    // relaxation of the requirement for an explicit successful terminal.
    func testStopWithoutDoneAcceptsOnlyCleanEOFWithArbitraryByteFragments() async throws {
        for separator in ["\n", "\r\n", "\r"] {
            for size in [1, 7, 65_536] {
                let fixture = "\u{feff}: heartbeat\(separator)\(separator)"
                    + "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"思考\",\"content\":\"答案\"},\"finish_reason\":\"stop\"}]}"
                StreamingURLProtocol.lines = fragmented(fixture, size: size)
                let result = try await receiveFixture()
                XCTAssertNil(result.error)
                XCTAssertEqual(result.text, "答案")
                XCTAssertEqual(result.reasoning, "思考")
            }
        }
    }

    func testMultilineDataAndStopTailWithoutFinalBlankLine() async throws {
        let fixture = "data: {\"choices\":[\n"
            + "data: {\"delta\":{\"content\":\"multiline\"},\"finish_reason\":null}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n"
        StreamingURLProtocol.lines = fragmented(fixture, size: 3)
        let result = try await receiveFixture()
        XCTAssertNil(result.error)
        XCTAssertEqual(result.text, "multiline")
    }

    func testDoneTailWithoutFinalNewlineCompletes() async throws {
        StreamingURLProtocol.lines = fragmented("data: {\"choices\":[{\"delta\":{\"content\":\"complete\"}}]}\n\ndata: [DONE]", size: 1)
        let result = try await receiveFixture()
        XCTAssertNil(result.error)
        XCTAssertEqual(result.text, "complete")
    }

    func testPartialTailIsPreservedButNeverCompleted() async throws {
        StreamingURLProtocol.lines = fragmented("data: {\"choices\":[{\"delta\":{\"content\":\"partial tail\"}}]}", size: 2)
        let result = try await receiveFixture()
        XCTAssertEqual(result.text, "partial tail")
        XCTAssertEqual(failureReason(result.error), .interrupted)
    }

    func testExplicitStopCompletesBeforeSubsequentMalformedBytes() async throws {
        StreamingURLProtocol.lines = fragmented("data: {\"choices\":[{\"delta\":{\"content\":\"answer\"},\"finish_reason\":\"stop\"}]}\n\ndata: {", size: 13)
        let result = try await receiveFixture()
        XCTAssertEqual(result.text, "answer")
        XCTAssertNil(result.error)
    }

    func testUsageOnlyChunkAfterStopWithoutDone() async throws {
        StreamingURLProtocol.lines = fragmented("data: {\"choices\":[{\"delta\":{\"content\":\"answer\"},\"finish_reason\":\"stop\"}]}\n\ndata: {\"choices\":[],\"usage\":{\"total_tokens\":4}}\n\n", size: 31)
        let result = try await receiveFixture()
        XCTAssertNil(result.error)
        XCTAssertEqual(result.text, "answer")
    }

    func testLongLegalEventIsNotTruncatedByTransportChunkSize() async throws {
        let answer = String(repeating: "答案", count: 12_000)
        let json: [String: Any] = ["choices": [["index": 0, "delta": ["content": answer], "finish_reason": "stop"]]]
        let encoded = try JSONSerialization.data(withJSONObject: json)
        let fixture = "data: " + String(decoding: encoded, as: UTF8.self) + "\n\n"
        for size in [97, 65_536] {
            StreamingURLProtocol.lines = fragmented(fixture, size: size)
            let result = try await receiveFixture()
            XCTAssertNil(result.error)
            XCTAssertEqual(result.text, answer)
        }
    }

    func testJSON200CompletionYieldsRealMessageAndBothReasoningSpellings() async throws {
        StreamingURLProtocol.contentType = "application/json; charset=utf-8"
        for reasoningKey in ["reasoning_content", "reasoning"] {
            let json: [String: Any] = ["object": "chat.completion", "choices": [["index": 0,
                "message": ["role": "assistant", "content": "真实答案", reasoningKey: "真实思考"], "finish_reason": "stop"]]]
            let data = try JSONSerialization.data(withJSONObject: json)
            StreamingURLProtocol.lines = data.map { Data([$0]) }
            let result = try await receiveFixture()
            XCTAssertNil(result.error)
            XCTAssertEqual(result.text, "真实答案")
            XCTAssertEqual(result.reasoning, "真实思考")
        }
    }

    func testJSONCompletionLargerThanErrorBufferStillPreservesFullContent() async throws {
        StreamingURLProtocol.contentType = "application/json"
        let text = String(repeating: "x", count: 32_000)
        let json: [String: Any] = ["choices": [["message": ["content": text], "finish_reason": "stop"]]]
        StreamingURLProtocol.lines = [try JSONSerialization.data(withJSONObject: json)]
        let result = try await receiveFixture()
        XCTAssertNil(result.error)
        XCTAssertEqual(result.text, text)
    }

    func testJSON200MissingFinishCannotCompleteFromTextAlone() async throws {
        StreamingURLProtocol.contentType = "application/json"
        StreamingURLProtocol.lines = [Data("{\"choices\":[{\"message\":{\"content\":\"partial\"}}]}".utf8)]
        let result = try await receiveFixture()
        XCTAssertEqual(result.text, "partial")
        XCTAssertEqual(failureReason(result.error), .interrupted)
    }

    func testAbnormalTerminalsPreserveSameFrameReasoningAndBodyThenFail() async throws {
        let terminals: [(String, MessageFailureReason)] = [
            ("length", .outputLimit), ("content_filter", .filtered),
            ("tool_calls", .unsupportedTool), ("function_call", .unsupportedTool)]
        for (reason, expected) in terminals {
            for isJSON in [false, true] {
                StreamingURLProtocol.contentType = isJSON ? "application/json" : "text/event-stream"
                let choice: [String: Any] = ["index": 0, "finish_reason": reason,
                    isJSON ? "message" : "delta": ["content": "last body", "reasoning_content": "last thought"]]
                let data = try JSONSerialization.data(withJSONObject: ["choices": [choice]])
                StreamingURLProtocol.lines = isJSON ? [data] : fragmented(
                    "data: " + String(decoding: data, as: UTF8.self) + "\n\ndata: [DONE]\n\n", size: 5)
                let result = try await receiveFixture()
                XCTAssertEqual(result.text, "last body")
                XCTAssertEqual(result.reasoning, "last thought")
                XCTAssertEqual(failureReason(result.error), expected)
            }
        }
    }

    func testJSON200ErrorEnvelopesTakePrecedenceOverChoicesAndHidePrivateText() async throws {
        StreamingURLProtocol.contentType = "application/json"
        let codes: [(String, MessageFailureReason)] = [
            ("UPSTREAM_BUSY", .busy), ("UPSTREAM_TIMEOUT", .timedOut),
            ("MODEL_UNAVAILABLE", .unavailable), ("UPSTREAM_UNAVAILABLE", .unavailable),
            ("UPSTREAM_CONFIGURATION", .unavailable), ("EMPTY_UPSTREAM", .invalidResponse),
            ("INVALID_UPSTREAM_RESPONSE", .invalidResponse), ("REQUEST_INTERRUPTED", .interrupted),
            ("MESSAGE_TOO_LARGE", .contextLimit),
            ("HISTORY_TOO_LARGE", .contextLimit), ("QUOTA_EXCEEDED", .requestFailed),
            ("private-unknown-code", .invalidResponse)]
        for (code, expected) in codes {
            for nested in [false, true] {
                let detail: [String: Any] = ["code": code,
                    "message": "fixture-fake-secret private prompt https://private.invalid"]
                var json: [String: Any] = nested ? ["error": detail] : detail
                json["choices"] = [["message": ["content": "must not yield"], "finish_reason": "stop"]]
                StreamingURLProtocol.lines = [try JSONSerialization.data(withJSONObject: json)]
                let result = try await receiveFixture()
                XCTAssertEqual(result.text, "")
                XCTAssertEqual(failureReason(result.error), expected)
                let description = result.error?.localizedDescription ?? ""
                XCTAssertFalse(description.contains("fixture-fake-secret"))
                XCTAssertFalse(description.contains("private"))
            }
        }
    }

    func testJSON200InvalidShapesAndUnknownFinishNeverComplete() async throws {
        StreamingURLProtocol.contentType = "application/json"
        for fixture in ["{}", "[]", "{\"choices\":[]}",
            "{\"choices\":[{\"message\":{\"content\":123},\"finish_reason\":\"stop\"}]}",
            "{\"choices\":[{\"delta\":{\"content\":\"wrong shape\"},\"finish_reason\":\"stop\"}]}" ] {
            StreamingURLProtocol.lines = fragmented(fixture, size: 3)
            let result = try await receiveFixture()
            XCTAssertEqual(failureReason(result.error), .invalidResponse)
        }
        for reason in ["end_turn", "completed", "eos", "private-unknown-finish"] {
            StreamingURLProtocol.lines = [Data("{\"choices\":[{\"message\":{\"content\":\"retained\"},\"finish_reason\":\"\(reason)\"}]}".utf8)]
            let result = try await receiveFixture()
            XCTAssertEqual(result.text, "retained")
            XCTAssertEqual(failureReason(result.error), .invalidResponse)
        }
    }

    func testUppercaseStopNormalizesButDoesNotAddUnverifiedAliases() async throws {
        StreamingURLProtocol.lines = [Data("data: {\"choices\":[{\"delta\":{\"content\":\"answer\"},\"finish_reason\":\"STOP\"}]}\n\n".utf8)]
        let result = try await receiveFixture()
        XCTAssertNil(result.error)
        XCTAssertEqual(result.text, "answer")
    }

    func testDisconnectFailsBeforeTerminalButExplicitStopWins() async throws {
        StreamingURLProtocol.deferErrorUntilChunk = true
        for hasStop in [false, true] {
            let reason = hasStop ? "\"stop\"" : "null"
            StreamingURLProtocol.lines = fragmented("data: {\"choices\":[{\"delta\":{\"content\":\"already received\"},\"finish_reason\":\(reason)}]}\n\n", size: 9)
            StreamingURLProtocol.transportError = URLError(.networkConnectionLost)
            let result = try await receiveFixture()
            XCTAssertEqual(result.text, "already received")
            if hasStop { XCTAssertNil(result.error) }
            else { XCTAssertEqual(failureReason(result.error), .interrupted) }
        }
    }

    func testClientTimeoutUsesFixedLocalCopyAndClassification() async throws {
        StreamingURLProtocol.transportError = URLError(.timedOut,
            userInfo: [NSURLErrorFailingURLStringErrorKey: "https://private.invalid/fixture-fake-secret"])
        let result = try await receiveFixture()
        XCTAssertEqual(failureReason(result.error), .timedOut)
        XCTAssertEqual(result.error?.localizedDescription, "连接模型服务超时，请稍后重试；本地对话已保留。")
    }

    func testErrorEventOrJSONErrorAfterPartialTextStillFails() async throws {
        let prefix = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n"
        for tail in ["event: error\ndata: {\"error\":{\"message\":\"private\"}}",
            "data: {\"error\":{\"code\":\"UPSTREAM_BUSY\",\"message\":\"private\"}}\n\ndata: [DONE]\n\n"] {
            StreamingURLProtocol.lines = fragmented(prefix + tail, size: 1)
            let result = try await receiveFixture()
            XCTAssertEqual(result.text, "partial")
            XCTAssertNotNil(result.error)
            XCTAssertFalse((result.error?.localizedDescription ?? "").contains("private"))
        }
    }

    func testSSELineAndEventBoundsAndInvalidUTF8FailClosed() async throws {
        let large = String(repeating: "x", count: 256 * 1_024)
        for fixture in ["data: " + large,
            "data: " + String(repeating: "x", count: 140_000) + "\n"
                + "data: " + String(repeating: "x", count: 140_000) + "\n\n"] {
            StreamingURLProtocol.lines = fragmented(fixture, size: 8192)
            let result = try await receiveFixture()
            XCTAssertEqual(failureReason(result.error), .invalidResponse)
        }
        StreamingURLProtocol.lines = [Data("data: ".utf8), Data([0xff, 0x0a, 0x0a])]
        let invalid = try await receiveFixture()
        XCTAssertEqual(failureReason(invalid.error), .invalidResponse)
    }

    func testServerKeeps180SecondTimeoutAndEntireRequestContext() async throws {
        let conversation = (0..<101).map { index in
            ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: "turn-\(index)")
        }
        StreamingURLProtocol.lines = [Data("data: {\"choices\":[{\"delta\":{\"content\":\"fixture answer\"},\"finish_reason\":\"stop\"}]}\n\n".utf8)]
        let adapter = backend(profile(.amoreServer))
        let stream = try await adapter.stream(messages: conversation, options: plain)
        for try await _ in stream {}
        XCTAssertGreaterThanOrEqual(StreamingURLProtocol.capturedRequest?.timeoutInterval ?? 0, 180)
        XCTAssertEqual(StreamingURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Accept"),
                       "text/event-stream, application/json")
        let data = try adapter.requestBody(messages: conversation, options: plain)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sent = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 102)
        XCTAssertEqual(sent[1]["content"] as? String, "turn-0")
        XCTAssertEqual(sent.last?["content"] as? String, "turn-100")
        XCTAssertNil(json["max_tokens"])
        XCTAssertNil(json["max_completion_tokens"])
    }

    func testHTTPErrorBufferStaysBoundedAndStatusClassificationIsLocal() async throws {
        StreamingURLProtocol.status = 400
        StreamingURLProtocol.contentType = "application/json"
        // If receive accidentally starts buffering the entire error, the code at
        // the end would select busy instead of the expected generic HTTP failure.
        let json: [String: Any] = ["padding": String(repeating: "x", count: 40_000), "code": "UPSTREAM_BUSY"]
        let data = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        // Force code to the tail rather than relying on dictionary key order.
        let fixture = "{\"padding\":\"" + String(repeating: "x", count: 40_000)
            + "\",\"code\":\"UPSTREAM_BUSY\"}"
        XCTAssertGreaterThan(data.count, 16 * 1_024)
        StreamingURLProtocol.lines = fragmented(fixture, size: 1024)
        let bounded = try await receiveFixture()
        XCTAssertEqual(failureReason(bounded.error), .requestFailed)
        XCTAssertTrue((bounded.error?.localizedDescription ?? "").contains("400"))
        for (status, expected) in [(401, MessageFailureReason.authentication),
                                   (403, .authentication), (504, .timedOut)] {
            StreamingURLProtocol.status = status
            StreamingURLProtocol.lines = [Data("{\"message\":\"private\"}".utf8)]
            let result = try await receiveFixture()
            XCTAssertEqual(failureReason(result.error), expected)
            XCTAssertFalse((result.error?.localizedDescription ?? "").contains("private"))
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
    func testStopCompletesAndCancelsConnectionThatStaysOpen() async throws {
        StreamingURLProtocol.holdOpen = true
        let stopped = expectation(description: "Explicit stop cancels remaining transport")
        StreamingURLProtocol.stopExpectation = stopped
        StreamingURLProtocol.lines = fragmented("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"finished\"},\"finish_reason\":\"stop\"}]}\n\n", size: 7)
        let result = try await receiveFixture()
        XCTAssertNil(result.error)
        XCTAssertEqual(result.text, "finished")
        await fulfillment(of: [stopped], timeout: 5)
    }

    func testEmptyStreamOrRoleOnlyCannotBecomeComplete() async throws {
        for fixture in [
            "data: [DONE]\n\n",
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\ndata: [DONE]\n\n",
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"  \"},\"finish_reason\":\"stop\"}]}\n\n"
        ] {
            StreamingURLProtocol.lines = fragmented(fixture, size: 3)
            let result = try await receiveFixture()
            XCTAssertEqual(failureReason(result.error), .invalidResponse)
        }
        StreamingURLProtocol.contentType = "application/json"
        StreamingURLProtocol.lines = [Data("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":\"stop\"}]}".utf8)]
        let result = try await receiveFixture()
        XCTAssertEqual(failureReason(result.error), .invalidResponse)
    }

}
