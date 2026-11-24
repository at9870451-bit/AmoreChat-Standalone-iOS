import Foundation
import Observation

@MainActor @Observable final class ChatController {
    var sessions: [ChatSession] = []
    var currentID: UUID?
    var draft = "" {
        didSet {
            if currentID == nil, !draft.isEmpty {
                let session = ChatSession(draft: draft)
                sessions.insert(session, at: 0)
                currentID = session.id
                persist()
                return
            }
            guard let id = currentID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            if sessions[index].draft != draft {
                sessions[index].draft = draft
                persist()
            }
        }
    }
    var attachments: [ChatAttachment] = [] {
        didSet {
            if currentID == nil, !attachments.isEmpty {
                let session = ChatSession(draftAttachments: attachments)
                sessions.insert(session, at: 0)
                currentID = session.id
                persist()
                return
            }
            guard let id = currentID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            if sessions[index].draftAttachments != attachments {
                sessions[index].draftAttachments = attachments
                persist()
            }
        }
    }
    var thinkingEnabled = false
    var webSearchEnabled = false
    var isGenerating = false
    var isLoading = true
    private(set) var isImporting = false
    var errorText: String?
    var backendReady: Bool { backend.isConfigured }
    var selectedModelName: String? { injectedBackend ? nil : catalog.active?.label }
    var supportsThinking: Bool { injectedBackend || (catalog.active != nil && catalog.active?.provider != .custom) }
    var supportsWebSearch: Bool {
        guard !injectedBackend, let profile = catalog.active,
              profile.provider == .openRouter,
              let components = URLComponents(string: profile.baseURL) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "openrouter.ai"
    }
    var messages: [ChatMessage] {
        guard let currentID else { return [] }
        return sessions.first(where: { $0.id == currentID })?.messages ?? []
    }

    private let archive: ChatArchive
    private let catalog: ModelCatalog
    private let injectedBackend: Bool
    private var backend: any ChatBackend
    private var streamTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(archive: ChatArchive = ChatArchive(), backend: (any ChatBackend)? = nil,
         catalog: ModelCatalog? = nil) {
        self.archive = archive
        self.catalog = catalog ?? ModelCatalog.shared
        self.injectedBackend = backend != nil
        self.backend = backend ?? UnconfiguredBackend()
        if backend == nil { refreshBackend() }
        Task { await load() }
    }

    func refreshBackend() {
        guard !injectedBackend else { return }
        guard !isGenerating else { errorText = "请先停止生成，再切换模型。"; return }
        guard let profile = catalog.active,
              let key = catalog.apiKey(for: profile.id), !key.isEmpty else {
            backend = UnconfiguredBackend()
            return
        }
        backend = OpenAICompatibleBackend(profile: profile, apiKey: key)
    }

    func selectModel(_ id: UUID) {
        guard !isGenerating else { errorText = "请先停止生成，再切换模型。"; return }
        catalog.select(id)
        refreshBackend()
    }

    func load() async {
        defer { isLoading = false }
        do {
            var stored = try await archive.load()
            var recoveredInterruptedReply = false
            for i in stored.indices {
                for j in stored[i].messages.indices where stored[i].messages[j].status == .streaming {
                    stored[i].messages[j].status = .failed
                    recoveredInterruptedReply = true
                }
            }
            if sessions.isEmpty {
                sessions = stored.sorted(by: order)
                currentID = sessions.first?.id
                draft = sessions.first?.draft ?? ""
                attachments = sessions.first?.draftAttachments ?? []
                if recoveredInterruptedReply { persist() }
            }
        } catch {
            errorText = "读取本地会话失败：\(error.localizedDescription)"
        }
    }

    private func order(_ lhs: ChatSession, _ rhs: ChatSession) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        return lhs.updatedAt > rhs.updatedAt
    }

    func newChat() {
        guard !isGenerating && !isImporting else { errorText = "请先停止生成或等待导入完成。"; return }
        let session = ChatSession()
        sessions.insert(session, at: 0)
        currentID = session.id
        draft = ""
        attachments = []
        errorText = nil
        persist()
    }

    func open(_ id: UUID) {
        guard !isGenerating && !isImporting else { errorText = "请先停止生成或等待导入完成。"; return }
        guard sessions.contains(where: { $0.id == id }) else { return }
        currentID = id
        draft = sessions.first(where: { $0.id == id })?.draft ?? ""
        attachments = sessions.first(where: { $0.id == id })?.draftAttachments ?? []
        errorText = nil
    }

    func rename(_ id: UUID, _ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isImporting, !clean.isEmpty, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].title = String(clean.prefix(80)); sessions[i].updatedAt = .now
        sessions.sort(by: order); persist()
    }

    func pin(_ id: UUID) {
        guard !isImporting, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].isPinned.toggle(); sessions.sort(by: order); persist()
    }

    func delete(_ id: UUID) {
        guard !isImporting, !isGenerating, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let removed = sessions.remove(at: i)
        if currentID == id {
            currentID = sessions.first?.id
            draft = sessions.first?.draft ?? ""
            attachments = sessions.first?.draftAttachments ?? []
        }
        persist()
        Task {
            for attachment in removed.messages.flatMap(\.attachments) + removed.draftAttachments {
                await archive.removeMedia(attachment)
            }
        }
    }

    func exportSessions() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmoreChat-会话-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sessions).write(to: url, options: .atomic)
        return url
    }

    func importDeepSeek(_ result: DeepSeekImportResult) async throws -> (added: Int, duplicates: Int) {
        guard !isGenerating && !isLoading && !isImporting else {
            throw DeepSeekImportError.invalidData("请先停止生成或等待本地数据操作完成")
        }
        isImporting = true
        defer { isImporting = false }
        saveTask?.cancel()
        if let pending = saveTask { await pending.value }
        let merged = result.merging(into: sessions)
        guard merged.sessions.count <= 10_000 else {
            throw DeepSeekImportError.unsafeArchive("合并后的会话过多")
        }
        // Persist the full new snapshot atomically before updating the UI.
        // A ZIP validation error or failed save leaves existing chats untouched.
        try await archive.save(merged.sessions)
        sessions = merged.sessions.sorted(by: order)
        if currentID == nil, let first = sessions.first {
            currentID = first.id
            draft = first.draft
            attachments = first.draftAttachments
        }
        return (merged.added, merged.duplicates)
    }

    func deleteAllSessions() {
        guard !isImporting && !isGenerating else { errorText = "请先停止生成或等待导入完成。"; return }
        let previous = sessions
        currentID = nil
        sessions = []
        draft = ""
        attachments = []
        errorText = nil
        persist()
        Task {
            for attachment in previous.flatMap({ $0.messages.flatMap(\.attachments) + $0.draftAttachments }) {
                await archive.removeMedia(attachment)
            }
        }
    }

    func attach(_ url: URL) async {
        do { attachments.append(try await archive.importFile(url)) }
        catch { errorText = "附件导入失败：\(error.localizedDescription)" }
    }

    func attachImage(_ data: Data) async {
        do { attachments.append(try await archive.importImage(data)) }
        catch { errorText = "图片导入失败：\(error.localizedDescription)" }
    }

    func removeAttachment(_ id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = attachments.remove(at: index)
        Task { await archive.removeMedia(attachment) }
    }

    func send() {
        guard !isImporting, !isLoading, !isGenerating else { return }
        guard backendReady else { errorText = BackendUnavailable().localizedDescription; return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let selectedAttachments = attachments
        if currentID == nil { newChat() }
        guard let id = currentID else { return }
        let message = ChatMessage(role: .user, content: text, attachments: selectedAttachments)
        let history = (sessions.first(where: { $0.id == id })?.messages ?? []) + [message]
        draft = ""; attachments = []; errorText = nil
        append(message, to: id)
        startResponse(in: id, history: history)
    }

    func retry() {
        guard !isImporting, !isGenerating, backendReady, let id = currentID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var history = sessions[index].messages
        guard history.last?.role == .assistant, history.last?.status == .failed else { return }
        history.removeLast()
        guard history.last?.role == .user else { return }
        sessions[index].messages = history
        startResponse(in: id, history: history)
    }

    func regenerate() {
        guard !isImporting, !isGenerating, backendReady, let id = currentID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var history = sessions[index].messages
        guard history.last?.role == .assistant else { return }
        history.removeLast()
        guard history.last?.role == .user else { return }
        sessions[index].messages = history
        errorText = nil
        persist()
        startResponse(in: id, history: history)
    }

    /// Delete a suffix, not one arbitrary message from model-facing history.
    func deleteFromMessage(_ messageID: UUID) {
        guard !isImporting, !isGenerating, let id = currentID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              let offset = sessions[index].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        let removed = Array(sessions[index].messages[offset...])
        sessions[index].messages.removeSubrange(offset...)
        sessions[index].updatedAt = .now
        persist()
        Task {
            for attachment in removed.flatMap(\.attachments) {
                await archive.removeMedia(attachment)
            }
        }
    }

    func stop() { streamTask?.cancel() }

    private func startResponse(in id: UUID, history: [ChatMessage]) {
        let reply = ChatMessage(role: .assistant, content: "", status: .streaming)
        append(reply, to: id)
        isGenerating = true
        let options = ChatOptions(deepThinking: thinkingEnabled, webSearch: webSearchEnabled)
        streamTask = Task {
            do {
                let chunks = try await backend.stream(messages: history, options: options)
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    mutateReply(reply.id, in: id) { value in
                        switch chunk {
                        case .text(let text): value.content += text
                        case .reasoning(let text): value.reasoning = (value.reasoning ?? "") + text
                        }
                    }
                    persist()
                }
                try Task.checkCancellation()
                mutateReply(reply.id, in: id) { $0.status = .complete }
            } catch is CancellationError {
                mutateReply(reply.id, in: id) { $0.status = .failed }
                errorText = "已停止生成。"
            } catch {
                mutateReply(reply.id, in: id) { $0.status = .failed }
                errorText = "请求失败：\(error.localizedDescription)"
            }
            isGenerating = false; streamTask = nil; persist()
        }
    }

    private func append(_ message: ChatMessage, to id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].messages.append(message); sessions[i].updatedAt = .now
        if message.role == .user && sessions[i].title == "新对话" && !message.content.isEmpty {
            sessions[i].title = String(message.content.prefix(24))
        }
        sessions.sort(by: order); persist()
    }

    private func mutateReply(_ replyID: UUID, in id: UUID, _ edit: (inout ChatMessage) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }),
              let j = sessions[i].messages.firstIndex(where: { $0.id == replyID }) else { return }
        edit(&sessions[i].messages[j]); sessions[i].updatedAt = .now
    }

    private func persist() {
        saveTask?.cancel()
        let snapshot = sessions
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do { try await archive.save(snapshot) }
            catch { errorText = "无法保存会话：\(error.localizedDescription)" }
        }
    }
}
