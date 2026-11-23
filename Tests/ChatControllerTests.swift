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

    @MainActor func testExportAndClearLocalSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = ChatArchive(root: root)
        let controller = ChatController(archive: archive)
        await controller.load()
        controller.newChat()
        controller.draft = "仅本机草稿"
        let export = try controller.exportSessions()
        let saved = try JSONDecoder().decode([ChatSession].self, from: Data(contentsOf: export))
        XCTAssertEqual(saved.first?.draft, "仅本机草稿")
        controller.deleteAllSessions()
        try await Task.sleep(for: .milliseconds(450))
        let afterDeletion = try await archive.load()
        XCTAssertTrue(afterDeletion.isEmpty)
    }

    @MainActor func testUnconfiguredBackendNeverFabricatesAnswer() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ChatController(archive: ChatArchive(root: root), backend: UnconfiguredBackend())
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
