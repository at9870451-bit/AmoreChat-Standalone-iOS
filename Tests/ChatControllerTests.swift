import XCTest
@testable import AmoreChatStandalone

final class ChatControllerTests: XCTestCase {
    @MainActor func testNewChatAndRenamePersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = ChatArchive(root: root)
        let controller = ChatController(archive: archive)
        await controller.load()
        controller.newChat()
        guard let id = controller.currentID else { return XCTFail("No real session") }
        controller.rename(id, "  测试会话  ")
        XCTAssertEqual(controller.sessions.first?.title, "测试会话")
        try await Task.sleep(for: .milliseconds(450))
        let persisted = try await archive.load()
        XCTAssertEqual(persisted.first?.id, id)
        XCTAssertEqual(persisted.first?.title, "测试会话")
    }

    @MainActor func testUnconfiguredBackendNeverFabricatesAnswer() async {
        let controller = ChatController()
        await controller.load()
        controller.newChat()
        controller.draft = "你好"
        controller.send()
        XCTAssertFalse(controller.isGenerating)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertEqual(controller.draft, "你好")
        XCTAssertNotNil(controller.errorText)
    }
}
