import Foundation

// This project intentionally has no Amore/OpenMinis runtime or copied models.
enum ChatRole: String, Codable, Sendable { case user, assistant }
enum MessageStatus: String, Codable, Sendable { case complete, streaming, failed }

struct ChatAttachment: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let localURL: URL
    let type: String

    init(id: UUID = UUID(), name: String, localURL: URL, type: String) {
        self.id = id; self.name = name; self.localURL = localURL; self.type = type
    }
}

struct ChatMessage: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let role: ChatRole
    var content: String
    var reasoning: String?
    var attachments: [ChatAttachment]
    let createdAt: Date
    var status: MessageStatus

    init(id: UUID = UUID(), role: ChatRole, content: String,
         reasoning: String? = nil, attachments: [ChatAttachment] = [],
         createdAt: Date = .now, status: MessageStatus = .complete) {
        self.id = id; self.role = role; self.content = content
        self.reasoning = reasoning; self.attachments = attachments
        self.createdAt = createdAt; self.status = status
    }
}

struct ChatSession: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var draft: String
    var draftAttachments: [ChatAttachment]
    var messages: [ChatMessage]

    init(id: UUID = UUID(), title: String = "新对话", createdAt: Date = .now,
         updatedAt: Date = .now, isPinned: Bool = false, draft: String = "",
         draftAttachments: [ChatAttachment] = [], messages: [ChatMessage] = []) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.isPinned = isPinned; self.draft = draft
        self.draftAttachments = draftAttachments; self.messages = messages
    }
}

struct ChatOptions: Sendable {
    let deepThinking: Bool
    let webSearch: Bool
}

enum BackendChunk: Sendable {
    case text(String)
    case reasoning(String)
}

/// Adapter seam for a later, documented backend. No invented URL or responses.
protocol ChatBackend: Sendable {
    var isConfigured: Bool { get }
    func stream(messages: [ChatMessage], options: ChatOptions) async throws -> AsyncThrowingStream<BackendChunk, Error>
}

struct BackendUnavailable: LocalizedError {
    var errorDescription: String? { "尚未接入后端。请先提供服务地址和 API 文档。" }
}

struct UnconfiguredBackend: ChatBackend {
    let isConfigured = false
    func stream(messages: [ChatMessage], options: ChatOptions) async throws -> AsyncThrowingStream<BackendChunk, Error> {
        throw BackendUnavailable()
    }
}
