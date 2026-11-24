import Foundation

@MainActor enum AppControllerFactory {
    static func make() -> ChatController {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--isolated-ui-test") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ChatUITest-\(UUID().uuidString)", isDirectory: true)
            let archive = ChatArchive(root: root)
            if arguments.contains("--stream-ui-test") {
                return ChatController(archive: archive, backend: UITestReplyBackend())
            }
            return ChatController(archive: archive, backend: UnconfiguredBackend())
        }
        #endif
        return ChatController()
    }
}

#if DEBUG
/// In-process fixture only, explicitly enabled by the isolated XCUI test.
private struct UITestReplyBackend: ChatBackend {
    let isConfigured = true

    func stream(messages: [ChatMessage], options: ChatOptions) async throws -> AsyncThrowingStream<BackendChunk, Error> {
        let hold = messages.last?.content == "stop fixture"
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let clock = ContinuousClock()
                    continuation.yield(.reasoning("仅供模拟器测试的思考内容。"))
                    if hold { try await clock.sleep(for: .seconds(30)) }
                    else { try await clock.sleep(for: .milliseconds(310)) }
                    continuation.yield(.text("这是用于模拟器验收的回复。"))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
