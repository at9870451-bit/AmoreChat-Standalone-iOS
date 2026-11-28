import Foundation
import XCTest
@testable import AmoreChatStandalone

@MainActor private final class SwitchTestSecrets: ModelCredentialStore {
    private var values: [UUID: String] = [:]
    func read(for id: UUID) -> String? { values[id] }
    func save(_ value: String, for id: UUID) throws { values[id] = value }
    func remove(for id: UUID) { values.removeValue(forKey: id) }
}

/// The real controller/catalog/adapter run unchanged; all requests terminate here.
private final class SwitchContextURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        captured = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var snapshot = request
        if snapshot.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            snapshot.httpBody = data
        }
        Self.lock.lock()
        Self.captured.append(snapshot)
        let index = Self.captured.count
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"reply-\(index)\",\"reasoning_content\":\"private-reasoning-\(index)\"}}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ModelSwitchContextTests: XCTestCase {
    @MainActor private func waitForReply(_ controller: ChatController) async throws {
        for _ in 0..<250 {
            if !controller.isGenerating { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(controller.isGenerating, "Mock reply must finish")
        XCTAssertNil(controller.errorText)
        XCTAssertEqual(controller.messages.last?.status, .complete)
    }

    private func payload(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor func testBYOKSwitchAToBToAResendsFullHistoryAndKeepsDraftAttachments() async throws {
        SwitchContextURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "switch-context.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = ModelCatalog(defaults: defaults, secrets: SwitchTestSecrets())
        let a = ModelProfile(label: "A", provider: .deepSeek, modelID: "model-a")
        let b = ModelProfile(label: "B", provider: .openRouter, modelID: "vendor/model-b", appendV1: true)
        try catalog.save(a, apiKey: "fixture-key-a")
        try catalog.save(b, apiKey: "fixture-key-b")
        let textURL = root.appendingPathComponent("context.txt")
        try Data("attachment fact ORCHID-1942".utf8).write(to: textURL)
        let file = ChatAttachment(name: "context.txt", localURL: textURL, type: "text/plain")
        let imageURL = root.appendingPathComponent("pixel.png")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6P1sAAAAASUVORK5CYII="))
        try png.write(to: imageURL)
        let image = ChatAttachment(name: "pixel.png", localURL: imageURL, type: "image/png")
        var original = [ChatMessage]()
        // More than TranscriptView's visibleLimit=80: the first turns must go on wire.
        for turn in 0..<42 {
            original.append(ChatMessage(role: .user, content: "original-user-\(turn)",
                attachments: turn == 0 ? [file, image] : []))
            original.append(ChatMessage(role: .assistant, content: "original-assistant-\(turn)",
                reasoning: "private-original-reasoning-\(turn)"))
        }
        original += [ChatMessage(role: .user, content: "interrupted question"),
                     ChatMessage(role: .assistant, content: "", reasoning: "private failed thought", status: .failed),
                     ChatMessage(role: .user, content: "follow-up question"),
                     ChatMessage(role: .assistant, content: "partial answer retained", status: .failed)]
        let chat = ChatSession(draft: "continue-0", draftAttachments: [file, image], messages: original)
        let archive = ChatArchive(root: root.appendingPathComponent("archive"))
        try await archive.save([chat])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SwitchContextURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = ChatController(archive: archive, catalog: catalog, modelSession: session)
        await controller.load()
        for (step, profile) in [a, b, a].enumerated() {
            let before = controller.messages
            controller.selectModel(profile.id)
            XCTAssertEqual(controller.currentID, chat.id)
            XCTAssertEqual(controller.sessions.count, 1)
            XCTAssertEqual(controller.messages, before)
            XCTAssertEqual(controller.draft, "continue-\(step)")
            XCTAssertEqual(controller.attachments, [file, image])
            XCTAssertEqual(controller.sessions.first?.draftAttachments, [file, image])
            XCTAssertEqual(Array(controller.messages.prefix(original.count)), original)
            XCTAssertFalse(controller.webSearchEnabled, "Paid search consent resets on switch")
            XCTAssertTrue(controller.setThinking(true))
            if step == 1 { XCTAssertTrue(controller.setWebSearch(true)) }
            controller.send()
            XCTAssertTrue(controller.isGenerating)
            try await waitForReply(controller)
            XCTAssertEqual(controller.currentID, chat.id)
            let request = try XCTUnwrap(SwitchContextURLProtocol.requests.last)
            XCTAssertEqual(SwitchContextURLProtocol.requests.count, step + 1)
            XCTAssertEqual(request.url, try ModelEndpoint.url(profile, suffix: "chat/completions"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key-\(step == 1 ? "b" : "a")")
            let json = try payload(request)
            XCTAssertEqual(json["model"] as? String, profile.modelID)
            let sent = try XCTUnwrap(json["messages"] as? [[String: Any]])
            XCTAssertGreaterThan(sent.count, 80)
            XCTAssertEqual(sent.first?["content"] as? String, BuiltInPersona.instruction)
            let strings = sent.compactMap { $0["content"] as? String }
            for turn in 1..<42 { XCTAssertTrue(strings.contains("original-user-\(turn)")) }
            for turn in 0..<42 { XCTAssertTrue(strings.contains("original-assistant-\(turn)")) }
            XCTAssertTrue(strings.contains("interrupted question\n\nfollow-up question"))
            XCTAssertTrue(strings.contains("partial answer retained"))
            for reply in 1..<(step + 1) { XCTAssertTrue(strings.contains("reply-\(reply)")) }
            for index in 1..<sent.count {
                XCTAssertNotEqual(sent[index]["role"] as? String, sent[index - 1]["role"] as? String)
                XCTAssertNil(sent[index]["reasoning_content"])
                XCTAssertNil(sent[index]["reasoning"])
                if sent[index]["role"] as? String == "assistant" {
                    XCTAssertFalse((sent[index]["content"] as? String ?? "").isEmpty)
                }
            }
            let firstParts = try XCTUnwrap(sent[1]["content"] as? [[String: Any]])
            XCTAssertTrue(firstParts.compactMap { $0["text"] as? String }.joined().contains("attachment fact ORCHID-1942"))
            XCTAssertEqual((firstParts.last?["image_url"] as? [String: String])?["url"], "data:image/png;base64,\(png.base64EncodedString())")
            let lastParts = try XCTUnwrap(sent.last?["content"] as? [[String: Any]])
            XCTAssertTrue(lastParts.compactMap { $0["text"] as? String }.joined().contains("continue-\(step)"))
            XCTAssertEqual((lastParts.last?["image_url"] as? [String: String])?["url"], "data:image/png;base64,\(png.base64EncodedString())")
            if step == 1 {
                XCTAssertNil(json["thinking"])
                XCTAssertEqual((json["reasoning"] as? [String: Bool])?["enabled"], true)
                XCTAssertNotNil(json["plugins"])
            } else {
                XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "enabled")
                XCTAssertNil(json["reasoning"])
                XCTAssertNil(json["plugins"])
            }
            controller.draft = "continue-\(step + 1)"
            controller.attachments = [file, image]
        }
        await controller.flushLocalState()
        let persisted = try await archive.load()
        XCTAssertEqual(persisted.first?.id, chat.id)
        XCTAssertEqual(persisted.first?.draft, "continue-3")
        XCTAssertEqual(persisted.first?.draftAttachments, [file, image])
        XCTAssertEqual(Array(try XCTUnwrap(persisted.first?.messages).prefix(original.count)), original)
    }

    @MainActor func testServerSwitchAToBToAKeepsSessionAndResendsOriginalTurns() async throws {
        SwitchContextURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "switch-server.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = ModelCatalog(defaults: defaults, secrets: SwitchTestSecrets())
        let a = BackendServerModel(id: 31, label: "A", model: "server-model-a", provider: "fixture",
            supportsThinking: true, supportsWebSearch: false, maxOutputTokens: 4096, routeCount: 1)
        let b = BackendServerModel(id: 32, label: "B", model: "server-model-b", provider: "fixture",
            supportsThinking: false, supportsWebSearch: false, maxOutputTokens: 4096, routeCount: 1)
        let attachmentURL = root.appendingPathComponent("facts.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("server attachment fact".utf8).write(to: attachmentURL)
        let attachment = ChatAttachment(name: "facts.txt", localURL: attachmentURL, type: "text/plain")
        let original = [ChatMessage(role: .user, content: "original server question", attachments: [attachment]),
                        ChatMessage(role: .assistant, content: "original server answer", reasoning: "private server thought")]
        let chat = ChatSession(draft: "server continue 0", draftAttachments: [attachment], messages: original)
        let archive = ChatArchive(root: root.appendingPathComponent("archive"))
        try await archive.save([chat])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SwitchContextURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = ChatController(archive: archive, catalog: catalog, modelSession: session)
        await controller.load()
        controller.setServerAccessToken("fixture-server-token")
        controller.updateServerModels([a, b])
        var aProfileID: UUID?
        for (step, remote) in [a, b, a].enumerated() {
            let before = controller.messages
            controller.activateServerModel(remote)
            if step == 0 { aProfileID = catalog.activeID }
            if step == 2 { XCTAssertEqual(catalog.activeID, aProfileID) }
            XCTAssertEqual(controller.currentID, chat.id)
            XCTAssertEqual(controller.sessions.count, 1)
            XCTAssertEqual(controller.messages, before)
            XCTAssertEqual(controller.draft, "server continue \(step)")
            XCTAssertEqual(controller.attachments, [attachment])
            XCTAssertEqual(controller.sessions.first?.draftAttachments, [attachment])
            if remote.supportsThinking { XCTAssertTrue(controller.setThinking(true)) }
            controller.send()
            try await waitForReply(controller)
            let request = try XCTUnwrap(SwitchContextURLProtocol.requests.last)
            XCTAssertEqual(SwitchContextURLProtocol.requests.count, step + 1)
            XCTAssertEqual(request.url?.path, "/api/v1/ai/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream, application/json")
            XCTAssertGreaterThanOrEqual(request.timeoutInterval, 180)
            let json = try payload(request)
            XCTAssertEqual(json["model"] as? String, String(remote.id))
            XCTAssertEqual(json["reasoning_effort"] as? String, remote.supportsThinking ? "high" : nil)
            let sent = try XCTUnwrap(json["messages"] as? [[String: Any]])
            XCTAssertEqual(sent[2]["content"] as? String, "original server answer")
            XCTAssertTrue((sent[1]["content"] as? String ?? "").contains("server attachment fact"))
            XCTAssertTrue((sent.last?["content"] as? String ?? "").contains("server continue \(step)"))
            for reply in 1..<(step + 1) {
                XCTAssertTrue(sent.contains { $0["content"] as? String == "reply-\(reply)" })
            }
            XCTAssertTrue(sent.allSatisfy { $0["reasoning_content"] == nil && $0["reasoning"] == nil })
            controller.draft = "server continue \(step + 1)"
            controller.attachments = [attachment]
        }
        XCTAssertEqual(catalog.profiles.count, 2)
        XCTAssertEqual(controller.currentID, chat.id)
        await controller.flushLocalState()
        let saved = try await archive.load()
        XCTAssertEqual(saved.first?.id, chat.id)
        XCTAssertEqual(saved.first?.draft, "server continue 3")
        XCTAssertEqual(saved.first?.draftAttachments, [attachment])
        XCTAssertEqual(Array(try XCTUnwrap(saved.first?.messages).prefix(original.count)), original)
    }

    @MainActor func testReusedServerRouteIDCannotSendToDifferentModelOrClearDraft() async throws {
        SwitchContextURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "switch-stale.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = ModelCatalog(defaults: defaults, secrets: SwitchTestSecrets())
        let old = BackendServerModel(id: 31, label: "A", model: "model-a", provider: "fixture",
            supportsThinking: false, supportsWebSearch: false, maxOutputTokens: 4096, routeCount: 1)
        let reused = BackendServerModel(id: 31, label: "Other", model: "model-other", provider: "fixture",
            supportsThinking: false, supportsWebSearch: false, maxOutputTokens: 4096, routeCount: 1)
        catalog.activateServerModel(old)
        let profileID = catalog.activeID
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SwitchContextURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = ChatController(archive: ChatArchive(root: root), catalog: catalog, modelSession: session)
        await controller.load()
        controller.setServerAccessToken("fixture-server-token")
        controller.draft = "unsent draft"
        let chatID = controller.currentID
        controller.updateServerModels([reused])
        XCTAssertFalse(controller.backendReady)
        XCTAssertEqual(catalog.activeID, profileID)
        XCTAssertEqual(catalog.profiles.count, 1)
        XCTAssertEqual(controller.currentID, chatID)
        XCTAssertEqual(controller.draft, "unsent draft")
        controller.send()
        XCTAssertTrue(SwitchContextURLProtocol.requests.isEmpty)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertEqual(controller.draft, "unsent draft")
        await controller.flushLocalState()
    }
}
