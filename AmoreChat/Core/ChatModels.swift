import Foundation

// This project intentionally has no Amore/OpenMinis runtime or copied models.
enum ChatRole: String, Codable, Sendable { case user, assistant }
enum MessageStatus: String, Codable, Sendable { case complete, streaming, failed }

/// Stored locally and optional on old archives; never substitutes partial output for success.
enum MessageFailureReason: String, Codable, Sendable {
    case cancelled, outputLimit, filtered, busy, timedOut, contextLimit, authentication
    case unavailable, interrupted, invalidResponse, unsupportedTool, requestFailed

    var label: String {
        switch self {
        case .cancelled: "已停止"
        case .outputLimit: "已达输出上限"
        case .filtered: "回复被服务商中止"
        case .busy: "模型繁忙"
        case .timedOut: "响应超时"
        case .contextLimit: "超出模型上下文"
        case .authentication: "登录或密钥已失效"
        case .unavailable: "模型暂不可用"
        case .interrupted: "连接中断"
        case .invalidResponse: "返回格式异常"
        case .unsupportedTool: "当前不支持工具回复"
        case .requestFailed: "请求未成功"
        }
    }
}

protocol ChatFailureClassifying: Error {
    var failureReason: MessageFailureReason { get }
}

struct ChatAttachment: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let localURL: URL
    let type: String
    let byteCount: Int?

    init(id: UUID = UUID(), name: String, localURL: URL, type: String, byteCount: Int? = nil) {
        self.id = id; self.name = name; self.localURL = localURL; self.type = type
        self.byteCount = byteCount
    }
}

struct ChatMessage: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let role: ChatRole
    var content: String
    var reasoning: String?
    /// nil identifies legacy/imported messages; infer only from their own nonempty reasoning.
    var thinkingRequested: Bool? = nil
    var reasoningDuration: TimeInterval? = nil
    var attachments: [ChatAttachment]
    let createdAt: Date
    var status: MessageStatus
    var failureReason: MessageFailureReason? = nil

    init(id: UUID = UUID(), role: ChatRole, content: String,
         reasoning: String? = nil, thinkingRequested: Bool? = nil,
         attachments: [ChatAttachment] = [],
         createdAt: Date = .now, status: MessageStatus = .complete) {
        self.id = id; self.role = role; self.content = content
        self.reasoning = reasoning; self.thinkingRequested = thinkingRequested
        self.attachments = attachments
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

/// Streams model text/reasoning from a selected user-provided service.
protocol ChatBackend: Sendable {
    var isConfigured: Bool { get }
    var supportsThinking: Bool { get }
    var supportsWebSearch: Bool { get }
    func stream(messages: [ChatMessage], options: ChatOptions) async throws -> AsyncThrowingStream<BackendChunk, Error>
}

extension ChatBackend {
    var supportsThinking: Bool { false }
    var supportsWebSearch: Bool { false }
}

struct BackendUnavailable: LocalizedError {
    var errorDescription: String? { "尚未配置 AI 模型。请在设置中添加服务商地址、模型 ID 和 API Key。" }
}

struct UnconfiguredBackend: ChatBackend {
    let isConfigured = false
    func stream(messages: [ChatMessage], options: ChatOptions) async throws -> AsyncThrowingStream<BackendChunk, Error> {
        throw BackendUnavailable()
    }
}
