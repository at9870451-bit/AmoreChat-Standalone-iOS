import XCTest
@testable import AmoreChatStandalone

private struct LocalTestBackend: ChatBackend {
    let isConfigured = true
    func stream(messages: [ChatMessage], options: ChatOptions) async throws -> AsyncThrowingStream<BackendChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.reasoning("检查输入"))
            continuation.yield(.text("真实测试响应"))
            continuation.finish()
        }
    }
}

final class StreamingTests: XCTestCase {
    @MainActor func testRealAdapterStreamsAndStores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = ChatArchive(root: root)
        let controller = ChatController(archive: archive, backend: LocalTestBackend())
        await controller.load()
        controller.newChat()
        controller.draft = "测试"
        controller.send()
        for _ in 0..<40 {
            if !controller.isGenerating { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(controller.messages.count, 2)
        XCTAssertEqual(controller.messages.last?.content, "真实测试响应")
        XCTAssertEqual(controller.messages.last?.reasoning, "检查输入")
        XCTAssertEqual(controller.messages.last?.status, .complete)
        try await Task.sleep(for: .milliseconds(350))
        let saved = try await archive.load()
        XCTAssertEqual(saved.first?.messages.count, 2)
    }
}
