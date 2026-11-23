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
    var errorText: String?
    var backendReady: Bool { backend.isConfigured }
    var messages: [ChatMessage] {
        guard let currentID else { return [] }
        return sessions.first(where: { $0.id == currentID })?.messages ?? []
    }

    private let archive: ChatArchive
    private let backend: any ChatBackend
    private var streamTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(archive: ChatArchive = ChatArchive(), backend: any ChatBackend = UnconfiguredBackend()) {
        self.archive = archive
        self.backend = backend
        Task { await load() }
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
        guard !isGenerating else { errorText = "请先停止生成，再切换会话。"; return }
        let session = ChatSession()
        sessions.insert(session, at: 0)
        currentID = session.id
        draft = ""
        attachments = []
        errorText = nil
        persist()
    }

    func open(_ id: UUID) {
        guard !isGenerating else { errorText = "请先停止生成，再切换会话。"; return }
        guard sessions.contains(where: { $0.id == id }) else { return }
        currentID = id
        draft = sessions.first(where: { $0.id == id })?.draft ?? ""
        attachments = sessions.first(where: { $0.id == id })?.draftAttachments ?? []
        errorText = nil
    }

    func rename(_ id: UUID, _ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].title = String(clean.prefix(80)); sessions[i].updatedAt = .now
        sessions.sort(by: order); persist()
    }

    func pin(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].isPinned.toggle(); sessions.sort(by: order); persist()
    }

    func delete(_ id: UUID) {
        guard !isGenerating, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
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
        guard !isLoading, !isGenerating else { return }
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
        guard !isGenerating, backendReady, let id = currentID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var history = sessions[index].messages
        guard history.last?.role == .assistant, history.last?.status == .failed else { return }
        history.removeLast()
        guard history.last?.role == .user else { return }
        sessions[index].messages = history
        startResponse(in: id, history: history)
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
