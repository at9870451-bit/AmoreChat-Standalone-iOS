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
    private(set) var thinkingEnabled = false
    private(set) var webSearchEnabled = false
    var isGenerating = false
    var isLoading = true
    var canRetry: Bool { backendReady && !isGenerating && messages.last?.status == .failed && messages.last?.role == .assistant }
    private(set) var completedReplyText: String?
    private(set) var isImporting = false
    private(set) var isAttachingFile = false
    private(set) var uploadFileLimitBytes: Int64 = .max
    private(set) var uploadImageLimitBytes: Int64 = .max
    var errorText: String?
    private(set) var serverAccessToken: String?
    var backendReady: Bool { backend.isConfigured }
    var selectedModelName: String? { injectedBackend ? injectedModelName : catalog.active?.label }
    var supportsThinking: Bool { backendReady && backend.supportsThinking }
    var supportsWebSearch: Bool { backendReady && backend.supportsWebSearch }
    var messages: [ChatMessage] {
        guard let currentID else { return [] }
        return sessions.first(where: { $0.id == currentID })?.messages ?? []
    }

    private let archive: ChatArchive
    private let catalog: ModelCatalog
    private let injectedBackend: Bool
    private let injectedModelName: String?
    /// A transport seam lets switch tests use the real adapter without networking.
    private let modelSession: URLSession
    private var backend: any ChatBackend
    private var streamTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var archiveWriteTask: Task<Void, Never>?
    @ObservationIgnored private var replyBuffer: ReplyStreamBuffer?
    @ObservationIgnored private var availableServerModels: [BackendServerModel]?
    @ObservationIgnored private var pendingServerModels: [BackendServerModel]?
    @ObservationIgnored private var replyFlushTask: Task<Void, Never>?
    @ObservationIgnored private var streamCheckpointTask: Task<Void, Never>?
    private let replyPublicationInterval: TimeInterval = 1.0 / 30.0

    init(archive: ChatArchive = ChatArchive(), backend: (any ChatBackend)? = nil,
         catalog: ModelCatalog? = nil, injectedModelName: String? = nil,
         modelSession: URLSession = .shared) {
        self.archive = archive
        self.modelSession = modelSession
        self.catalog = catalog ?? ModelCatalog.shared
        self.injectedBackend = backend != nil
        self.injectedModelName = injectedModelName
        self.backend = backend ?? UnconfiguredBackend()
        if backend == nil { refreshBackend() }
        Task { await load() }
    }

    func refreshBackend() {
        guard !injectedBackend else { return }
        guard !isGenerating else { errorText = "请先停止生成，再切换模型。"; return }
        let profile = catalog.active
        if let profile, profile.provider == .amoreServer {
            if let models = availableServerModels,
               !models.contains(where: { remote in
                   String(remote.id) == profile.modelID && profile.serverModelName == remote.model
               }) {
                backend = UnconfiguredBackend()
                webSearchEnabled = false
                thinkingEnabled = false
                errorText = "当前服务器模型已变更，请在模型列表重新选择；本地会话和草稿已保留。"
                return
            }
            if let token = serverAccessToken, !token.isEmpty {
                backend = OpenAICompatibleBackend(profile: profile, apiKey: token, session: modelSession)
            } else {
                backend = UnconfiguredBackend()
            }
        } else if let profile, let key = catalog.apiKey(for: profile.id), !key.isEmpty {
            backend = OpenAICompatibleBackend(profile: profile, apiKey: key, session: modelSession)
        } else {
            backend = UnconfiguredBackend()
        }
        // Paid search consent applies to the current configuration, not a new key/model.
        webSearchEnabled = false
        if !supportsThinking || !backendReady { thinkingEnabled = false }
        errorText = nil
    }

    @discardableResult
    func setThinking(_ enabled: Bool) -> Bool {
        guard !isLoading, !isImporting, !isGenerating, !enabled || supportsThinking else { return false }
        thinkingEnabled = enabled
        return true
    }

    @discardableResult
    func setWebSearch(_ enabled: Bool) -> Bool {
        guard !isLoading, !isImporting, !isGenerating, !enabled || supportsWebSearch else { return false }
        webSearchEnabled = enabled
        return true
    }

    func selectModel(_ id: UUID) {
        guard !isGenerating else { errorText = "请先停止生成，再切换模型。"; return }
        catalog.select(id)
        refreshBackend()
    }

    /// Changing the transport never creates/opens a chat or rewrites its draft.
    func activateServerModel(_ model: BackendServerModel) {
        guard !isGenerating else { errorText = "请先停止生成，再切换模型。"; return }
        catalog.activateServerModel(model)
        refreshBackend()
    }

    /// Call only after a successful authenticated list refresh, not a transient
    /// loading/error/unauthenticated empty list. Never switches or clears a chat.
    func updateServerModels(_ models: [BackendServerModel]) {
        guard !injectedBackend else { return }
        guard !isGenerating else { pendingServerModels = models; return }
        availableServerModels = models
        catalog.reconcileServerModels(models)
        if catalog.active?.provider == .amoreServer { refreshBackend() }
    }

    func setServerAccessToken(_ token: String?) {
        guard serverAccessToken != token else { return }
        serverAccessToken = token
        guard !injectedBackend else { return }
        if catalog.active?.provider == .amoreServer { refreshBackend() }
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
        saveTask = nil
        // Join any already-enqueued checkpoint/final write before the atomic import.
        if let pending = archiveWriteTask { await pending.value }
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
        guard !isLoading, !isGenerating, !isImporting, !isAttachingFile else { return }
        let sessionAtSelection = currentID
        isAttachingFile = true
        defer { isAttachingFile = false }
        do {
            let file = try await archive.importFile(url, maxBytes: Int(uploadFileLimitBytes))
            if !Task.isCancelled && currentID == sessionAtSelection && !isImporting && !isGenerating {
                attachments.append(file)
                errorText = nil
            } else {
                await archive.removeMedia(file)
                if !Task.isCancelled { errorText = "会话已切换，请重新选择文件。" }
            }
        } catch is CancellationError {
            return
        } catch {
            errorText = "附件导入失败：\(error.localizedDescription)"
        }
    }

    func attachImage(_ data: Data) async {
        guard Int64(data.count) <= uploadImageLimitBytes else {
            errorText = "图片超过后台设置的 \(ByteCountFormatter.string(fromByteCount: uploadImageLimitBytes, countStyle: .file)) 上限。"
            return
        }
        do { attachments.append(try await archive.importImage(data)) }
        catch { errorText = "图片导入失败：\(error.localizedDescription)" }
    }

    func removeAttachment(_ id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = attachments.remove(at: index)
        Task { await archive.removeMedia(attachment) }
    }

    func send() {
        guard !isImporting, !isLoading, !isGenerating, !isAttachingFile else { return }
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
        guard history.last?.role == .assistant, history.last?.status == .failed,
              history.dropLast().last?.role == .user else { return }
        history.removeLast()
        errorText = nil
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
        let options = ChatOptions(deepThinking: thinkingEnabled && supportsThinking,
                                  webSearch: webSearchEnabled && supportsWebSearch)
        let reply = ChatMessage(role: .assistant, content: "",
                                thinkingRequested: options.deepThinking, status: .streaming)
        append(reply, to: id)
        isGenerating = true
        completedReplyText = nil
        replyBuffer = ReplyStreamBuffer(sessionID: id, replyID: reply.id)
        startStreamCheckpoints(for: reply.id)
        streamTask = Task {
            var status: MessageStatus = .complete
            do {
                let chunks = try await backend.stream(messages: history, options: options)
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    receive(chunk)
                    // No artificial delay/backpressure; let UI and timer tasks run even
                    // when AsyncThrowingStream already has a large backlog of chunks.
                    await Task.yield()
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                status = .failed
                errorText = "已停止生成。"
            } catch {
                status = .failed
                errorText = "请求失败：\(error.localizedDescription)"
            }
            // All exit paths publish pending real content and close the monotonic timer.
            replyBuffer?.finishTiming(now: ProcessInfo.processInfo.systemUptime)
            flushPendingReply()
            mutateReply(reply.id, in: id) { $0.status = status }
            if status == .complete, let answer = replyBuffer?.answer,
               !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completedReplyText = answer
            }
            replyFlushTask?.cancel(); replyFlushTask = nil
            streamCheckpointTask?.cancel(); streamCheckpointTask = nil
            replyBuffer = nil
            isGenerating = false; streamTask = nil
            if let models = pendingServerModels {
                pendingServerModels = nil
                updateServerModels(models)
            }
            persistImmediately()
        }
    }

    private func receive(_ chunk: BackendChunk) {
        guard let buffer = replyBuffer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        buffer.append(chunk, now: now)
        let elapsed = buffer.lastPublication.map { now - $0 } ?? replyPublicationInterval
        if elapsed >= replyPublicationInterval {
            // First delta is immediate; later publications are at most 30 Hz.
            replyFlushTask?.cancel(); replyFlushTask = nil
            flushPendingReply()
        } else if replyFlushTask == nil {
            let deadline = now + max(0, replyPublicationInterval - elapsed)
            let replyID = buffer.replyID
            replyFlushTask = Task { [weak self] in
                let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                do { try await Task.sleep(for: .seconds(remaining), tolerance: .milliseconds(1)) }
                catch { return }
                guard !Task.isCancelled, let self, self.replyBuffer?.replyID == replyID else { return }
                self.replyFlushTask = nil
                self.flushPendingReply()
            }
        }
    }

    private func flushPendingReply() {
        guard let buffer = replyBuffer, buffer.hasPending else { return }
        let delta = buffer.takePending(now: ProcessInfo.processInfo.systemUptime)
        mutateReply(buffer.replyID, in: buffer.sessionID) { value in
            value.content += delta.content
            if let reasoning = delta.reasoning {
                value.reasoning = (value.reasoning ?? "") + reasoning
            }
            if let duration = delta.reasoningDuration { value.reasoningDuration = duration }
        }
    }

    private func startStreamCheckpoints(for replyID: UUID) {
        streamCheckpointTask?.cancel()
        streamCheckpointTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard !Task.isCancelled, let self, self.replyBuffer?.replyID == replyID else { return }
                // Independent of chunk frequency: a continuous stream cannot debounce
                // every checkpoint away. Pending UI deltas follow their own 33ms timer.
                self.persistImmediately()
            }
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

    /// Publishes in-memory deltas and waits for this snapshot and older writes.
    /// Safe to call when the scene enters the background; generation may continue.
    func flushLocalState() async {
        guard !isImporting else { return }
        replyFlushTask?.cancel(); replyFlushTask = nil
        flushPendingReply()
        persistImmediately()
        if let pending = archiveWriteTask { await pending.value }
    }

    private func persist() {
        guard !isImporting else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard !Task.isCancelled, let self, !self.isImporting else { return }
            self.saveTask = nil
            // Capture only after the debounce, not on every edit/chunk. This avoids
            // keeping the entire sessions value shared throughout the delay.
            self.enqueueSnapshot()
        }
    }

    private func persistImmediately() {
        guard !isImporting else { return }
        saveTask?.cancel(); saveTask = nil
        enqueueSnapshot()
    }

    private func enqueueSnapshot() {
        let snapshot = sessions
        let previous = archiveWriteTask
        let archive = archive
        // Once enqueued a snapshot is never canceled. Explicitly join its predecessor
        // so a delayed checkpoint cannot overwrite a newer final/background snapshot.
        archiveWriteTask = Task { [weak self] in
            if let previous { await previous.value }
            do { try await archive.save(snapshot) }
            catch { self?.errorText = "无法保存会话：\(error.localizedDescription)" }
        }
    }
}
