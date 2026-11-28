import Foundation
import XCTest
@testable import AmoreChatStandalone

private struct CompletionFixtureError: LocalizedError, ChatFailureClassifying {
    let failureReason: MessageFailureReason
    var errorDescription: String? { "Synthetic output limit" }
}
private struct CompletionFixtureBackend: ChatBackend {
    let isConfigured = true
    let failure: MessageFailureReason?
    func stream(messages: [ChatMessage], options: ChatOptions) async throws -> AsyncThrowingStream<BackendChunk, Error> {
        AsyncThrowingStream { c in
            c.yield(.text("preserved answer"))
            if let failure { c.finish(throwing: CompletionFixtureError(failureReason: failure)) }
            else { c.finish() }
        }
    }
}

final class MessageCompletionStateTests: XCTestCase {
    func testLegacyArchiveMissingFailureReasonStillDecodes() throws {
        let message = ChatMessage(role: .assistant, content: "legacy text", status: .failed)
        let data = try JSONEncoder().encode(message)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "failureReason")
        object.removeValue(forKey: "thinkingRequested")
        let decoded = try JSONDecoder().decode(ChatMessage.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.status, .failed)
        XCTAssertEqual(decoded.content, "legacy text")
        XCTAssertNil(decoded.failureReason)
        XCTAssertNil(decoded.thinkingRequested)
    }

    @MainActor func testPartialOutputAndPreciseFailureRemainFailedAndPersist() async throws {
        for reason in [MessageFailureReason.outputLimit, .busy, .timedOut, .interrupted, .cancelled] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = ChatArchive(root: root)
            let controller = ChatController(archive: archive, backend: CompletionFixtureBackend(failure: reason))
            await controller.load(); controller.newChat(); controller.draft = "synthetic question"; controller.send()
            for _ in 0..<150 {
                if !controller.isGenerating { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(controller.isGenerating)
            XCTAssertEqual(controller.messages.last?.content, "preserved answer")
            XCTAssertEqual(controller.messages.last?.status, .failed)
            XCTAssertEqual(controller.messages.last?.failureReason, reason)
            XCTAssertNil(controller.completedReplyText)
            await controller.flushLocalState()
            let stored = try await archive.load()
            XCTAssertEqual(stored.first?.messages.last?.failureReason, reason)
            XCTAssertEqual(stored.first?.messages.last?.content, "preserved answer")
        }
    }

    @MainActor func testSuccessfulStreamHasNoFailureReason() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ChatController(archive: ChatArchive(root: root), backend: CompletionFixtureBackend(failure: nil))
        await controller.load(); controller.newChat(); controller.draft = "question"; controller.send()
        for _ in 0..<150 {
            if !controller.isGenerating { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(controller.isGenerating)
        XCTAssertEqual(controller.messages.last?.status, .complete)
        XCTAssertNil(controller.messages.last?.failureReason)
        XCTAssertEqual(controller.completedReplyText, "preserved answer")
    }
}
