import Foundation

@MainActor enum AppControllerFactory {
    static func make() -> ChatController {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--isolated-ui-test") {
            if arguments.contains("--import-folder-ui-test") { UITestDocuments.seedImportFolder() }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ChatUITest-\(UUID().uuidString)", isDirectory: true)
            let archive = ChatArchive(root: root)
            if arguments.contains("--stream-ui-test") {
                return ChatController(archive: archive, backend: UITestReplyBackend(), injectedModelName: "11")
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
    let supportsThinking = true
    let supportsWebSearch = true

    func stream(messages: [ChatMessage], options: ChatOptions) async throws -> AsyncThrowingStream<BackendChunk, Error> {
        let prompt = messages.last?.content
        let hold = prompt == "stop fixture"
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let clock = ContinuousClock()
                    continuation.yield(.reasoning("仅供模拟器测试的思考内容。"))
                    if hold { try await clock.sleep(for: .seconds(30)) }
                    else { try await clock.sleep(for: .milliseconds(310)) }
                    if prompt == "options fixture" {
                        continuation.yield(.text("测试请求：思考\(options.deepThinking ? "开" : "关")／搜索\(options.webSearch ? "开" : "关")"))
                    } else {
                        continuation.yield(.text("这是用于模拟器验收的回复。"))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
