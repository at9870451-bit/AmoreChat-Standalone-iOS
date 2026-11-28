import Foundation
import UIKit
import PDFKit
import ImageIO

/// One chat-completions transport. Credentials are never persisted or included in errors.
struct OpenAICompatibleBackend: ChatBackend {
    let profile: ModelProfile
    private let apiKey: String
    private let session: URLSession

    init(profile: ModelProfile, apiKey: String, session: URLSession = .shared) {
        self.profile = profile
        self.apiKey = apiKey
        self.session = session
    }

    // Configuration is validated at send time, so the controller can display the specific error.
    var isConfigured: Bool { true }
    var supportsThinking: Bool { profile.allowsThinking }
    var supportsWebSearch: Bool { profile.allowsWebSearch }

    func stream(messages: [ChatMessage], options: ChatOptions) async throws -> AsyncThrowingStream<BackendChunk, Error> {
        try Task.checkCancellation()
        let url = try endpoint()
        guard !apiKey.isEmpty, apiKey == apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw AdapterError.invalidKey }
        guard !messages.isEmpty else { throw AdapterError.emptyConversation }
        guard !options.webSearch || supportsWebSearch else { throw AdapterError.unsupportedWebSearch }
        guard !options.deepThinking || profile.allowsThinking else { throw AdapterError.unsupportedThinking }
        let body = try requestBody(messages: messages, options: options)
        try Task.checkCancellation()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Success is SSE; gateways return bounded JSON errors (429/5xx).
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        // The server may spend 120s waiting for an upstream before its finite retry.
        // URLSession's default 60s would abandon an otherwise valid server reply.
        if profile.provider == .amoreServer { request.timeoutInterval = 180 }
        request.httpBody = body
        // Never follow a Location header with the bearer token to another origin.
        let transport = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.receive(request: request, session: transport, continuation: continuation)
                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else if let safe = error as? AdapterError {
                        continuation.finish(throwing: safe)
                    } else {
                        // URLSession errors and server bodies may contain sensitive URLs/text.
                        continuation.finish(throwing: AdapterError.networkFailure)
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func endpoint() throws -> URL {
        guard profile.format == .chatCompletions,
              !profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profile.modelID == profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
              !profile.modelID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw AdapterError.invalidModel }
        let trimmed = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let input = URLComponents(string: trimmed), input.scheme?.lowercased() == "https",
              let host = input.host, !host.isEmpty, input.user == nil, input.password == nil,
              input.query == nil, input.fragment == nil, input.percentEncodedQuery == nil,
              input.percentEncodedFragment == nil, !input.percentEncodedPath.contains("%"),
              !input.path.contains("//"),
              !input.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              input.path.split(separator: "/").filter({ $0.lowercased() == "v1" }).count <= 1
        else { throw AdapterError.invalidURL }
        let path = input.path.split(separator: "/").map { $0.lowercased() }
        guard !path.suffix(2).elementsEqual(["chat", "completions"]),
              !(profile.appendV1 && path.contains("v1") && path.last != "v1")
        else { throw AdapterError.invalidURL }
        // ModelEndpoint normalizes provider prefixes (/api, /v1) and avoids /v1/v1.
        guard let url = try? ModelEndpoint.url(profile, suffix: "chat/completions"),
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false),
              target.scheme?.lowercased() == "https", target.host == host,
              target.user == nil, target.password == nil, target.query == nil, target.fragment == nil
        else { throw AdapterError.invalidURL }
        return url
    }

    func requestBody(messages: [ChatMessage], options: ChatOptions) throws -> Data {
        var encodedMessages = try requestMessages(messages)
        guard !encodedMessages.isEmpty else { throw AdapterError.emptyConversation }
        // The persona is a static built-in instruction only. It never contains
        // imported archive text or a user profile, and it is sent as a system
        // message so every configured provider gets the same conversational style.
        encodedMessages.insert(["role": "system", "content": BuiltInPersona.instruction], at: 0)
        var payload: [String: Any] = [
            "model": profile.modelID,
            "stream": true,
            "messages": encodedMessages
        ]
        switch profile.thinkingProtocol {
        case .deepSeekSwitch:
            payload["thinking"] = ["type": options.deepThinking ? "enabled" : "disabled"]
        case .reasoningEffort:
            if options.deepThinking { payload["reasoning_effort"] = "high" }
        case .openRouterReasoning:
            payload["reasoning"] = ["enabled": options.deepThinking]
        case nil: break
        }
        if options.webSearch && profile.allowsWebSearch {
            payload["plugins"] = [["id": "web"]]
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload)
        else { throw AdapterError.invalidRequest }
        return body
    }

    /// Normalize only the outgoing copy, never the local transcript. A stopped or
    /// failed reply may contain reasoning but no answer; sending an empty assistant
    /// can invalidate strict chat APIs. Keep partial answers regardless of status.
    /// Coalesce adjacent equal roles (including users separated by a failed reply)
    /// without inventing an answer or dropping any text/image part. No UI limit applies.
    private func requestMessages(_ messages: [ChatMessage]) throws -> [[String: Any]] {
        var result = [[String: Any]]()
        for message in messages {
            let hasText = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasText || !message.attachments.isEmpty else { continue }
            let encoded = try encodeMessage(message)
            if let last = result.last, last["role"] as? String == message.role.rawValue {
                var combined = last
                if let previous = last["content"] as? String, let next = encoded["content"] as? String {
                    combined["content"] = previous + "\n\n" + next
                } else {
                    combined["content"] = Self.contentParts(last["content"]) + Self.contentParts(encoded["content"])
                }
                result[result.count - 1] = combined
            } else {
                result.append(encoded)
            }
        }
        return result
    }

    private static func contentParts(_ content: Any?) -> [[String: Any]] {
        if let parts = content as? [[String: Any]] { return parts }
        if let text = content as? String { return [["type": "text", "text": text]] }
        return []
    }

    private func encodeMessage(_ message: ChatMessage) throws -> [String: Any] {
        var result: [String: Any] = ["role": message.role.rawValue]
        if message.role == .assistant {
            guard message.attachments.isEmpty else { throw AdapterError.unsupportedAttachment }
            result["content"] = message.content
            // This plain chat adapter does not send tool calls. Previously
            // displayed reasoning (including imported history) stays local.
            // It need not be echoed across models to continue a text chat.
            return result
        }
        var text = message.content
        var images = [[String: Any]]()
        for attachment in message.attachments {
            try Task.checkCancellation()
            guard attachment.localURL.isFileURL else { throw AdapterError.unsupportedAttachment }
            let mime = attachment.type.lowercased()
            let imageTypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif", "image/heic", "image/heif"]
            let textTypes: Set<String> = ["text/plain", "text/markdown", "text/csv", "text/xml", "application/json", "application/xml", "text/x-python", "text/x-yaml", "application/pdf"]
            let sourceSuffixes: Set<String> = ["c", "h", "cc", "cpp", "cxx", "hpp", "swift", "java", "js", "ts", "rs", "go", "py", "yaml", "yml"]
            let suffix = attachment.localURL.pathExtension.lowercased()
            guard imageTypes.contains(mime) || textTypes.contains(mime) || sourceSuffixes.contains(suffix)
            else { throw AdapterError.unsupportedAttachment }
            // No app-side size ceiling: the device and the chosen provider decide how large a request can be.
            guard let bytes = try? Data(contentsOf: attachment.localURL, options: .mappedIfSafe),
                  !bytes.isEmpty
            else { throw AdapterError.attachmentReadFailure }
            if imageTypes.contains(mime) {
                let uploadBytes: Data
                let uploadType: String
                if mime == "image/heic" || mime == "image/heif" {
                    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 8192, height <= 8192,
                          width * height <= 25_000_000,
                          let image = UIImage(data: bytes),
                          let converted = image.jpegData(compressionQuality: 0.82) else {
                        throw AdapterError.unsupportedAttachment
                    }
                    uploadBytes = converted; uploadType = "image/jpeg"
                } else {
                    guard Self.matchesImageSignature(bytes, mime: mime) else { throw AdapterError.unsupportedAttachment }
                    uploadBytes = bytes; uploadType = mime
                }
                images.append(["type": "image_url", "image_url": ["url": "data:\(uploadType);base64,\(uploadBytes.base64EncodedString())"]])
            } else {
                let content: String
                if mime == "application/pdf" {
                    guard bytes.starts(with: Array("%PDF-".utf8)),
                          let document = PDFDocument(data: bytes),
                          let extracted = document.string, !extracted.isEmpty else { throw AdapterError.unsupportedAttachment }
                    content = extracted
                } else {
                    guard let decoded = String(data: bytes, encoding: .utf8), !decoded.contains("\0")
                    else { throw AdapterError.unsupportedAttachment }
                    content = decoded
                }
                let name = String(attachment.name.prefix(100)).replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                text += "\n\n[Attached text file: \(name)]\n\(content)\n[/Attached text file]"
            }
        }
        if images.isEmpty {
            result["content"] = text
        } else {
            result["content"] = [["type": "text", "text": text]] + images
        }
        return result
    }

    private static func matchesImageSignature(_ data: Data, mime: String) -> Bool {
        switch mime {
        case "image/png": return data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        case "image/jpeg": return data.starts(with: [0xff, 0xd8, 0xff])
        case "image/gif": return data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8))
        case "image/webp": return data.count >= 12 && data.starts(with: Array("RIFF".utf8)) &&
            data.dropFirst(8).starts(with: Array("WEBP".utf8))
        default: return false
        }
    }

    private static func receive(request: URLRequest, session: URLSession,
                                continuation: AsyncThrowingStream<BackendChunk, Error>.Continuation) async throws {
        let (bytes, response) = try await session.bytes(for: request, delegate: RejectRedirects())
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AdapterError.invalidResponse }
        if !(200...299).contains(http.statusCode) ||
            http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true {
            // Never expose upstream bodies/URLs, and do not buffer an unbounded error.
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 16 * 1_024 else { break }
                data.append(byte)
            }
            throw responseError(data: data, status: http.statusCode)
        }
        var parser = SSEParser()
        var byteCount = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            byteCount += 1
            guard byteCount <= 16 * 1_024 * 1_024 else { throw AdapterError.invalidResponse }
            if let data = try parser.accept(byte) {
                if data == "[DONE]" { return }
                try emit(data: data, to: continuation)
            }
        }
        try Task.checkCancellation()
        throw AdapterError.interrupted // 2xx connection closing without [DONE] is not success.
    }

    private static func responseError(data: Data, status: Int) -> AdapterError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let nested = json?["error"] as? [String: Any]
        let code = (json?["code"] as? String) ?? (nested?["code"] as? String)
        // Only codes we recognize select fixed local copy. Arbitrary server text,
        // user prompts, account information and credentials never enter an error.
        switch code {
        case "UPSTREAM_BUSY", "RATE_LIMITED", "rate_limit_exceeded": return .busy(status)
        case "UPSTREAM_TIMEOUT": return .upstreamTimeout(status)
        case "MODEL_UNAVAILABLE": return .unavailableModel(status)
        case "QUOTA_EXCEEDED": return .quota(status)
        case "MESSAGE_TOO_LARGE", "HISTORY_TOO_LARGE", "context_length_exceeded": return .contextLimit(status)
        default:
            if status == 429 { return .busy(status) }
            if status == 504 { return .upstreamTimeout(status) }
            if status == 413 { return .contextLimit(status) }
            return (200...299).contains(status) ? .invalidResponse : .http(status)
        }
    }

    private static func emit(data: String, to continuation: AsyncThrowingStream<BackendChunk, Error>.Continuation) throws {
        guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]
        else { throw AdapterError.invalidResponse }
        if json["error"] != nil { throw AdapterError.serverFailure }
        guard let choices = json["choices"] as? [[String: Any]] else { throw AdapterError.invalidResponse }
        for choice in choices where (choice["index"] as? Int ?? 0) == 0 {
            if let reason = choice["finish_reason"] as? String {
                switch reason {
                case "stop": break
                case "length": throw AdapterError.incompleteOutput
                case "content_filter": throw AdapterError.filteredOutput
                case "tool_calls", "function_call": throw AdapterError.unsupportedToolCall
                default: throw AdapterError.invalidResponse
                }
            }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if let value = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String),
               !value.isEmpty { continuation.yield(.reasoning(value)) }
            if let value = delta["content"] as? String, !value.isEmpty { continuation.yield(.text(value)) }
        }
    }
}

/// No redirect is allowed, even to the same host: redirects may silently change method or path.
private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Byte-by-byte framing keeps a single SSE line/event bounded; UTF-8 may cross transport chunks.
private struct SSEParser {
    private var line = [UInt8]()
    private var dataLines = [String]()
    private var eventBytes = 0
    private var isError = false
    private let limit = 256 * 1_024

    mutating func accept(_ byte: UInt8) throws -> String? {
        if byte != 0x0a {
            guard line.count < limit else { throw AdapterError.invalidResponse }
            line.append(byte)
            return nil
        }
        if line.last == 0x0d { line.removeLast() }
        guard let text = String(bytes: line, encoding: .utf8) else { throw AdapterError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true); eventBytes = 0; isError = false }
            if isError { throw AdapterError.serverFailure }
            return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
        }
        if text.first == ":" { return nil }
        let pair = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = pair[0]
        let rawValue = pair.count > 1 ? String(pair[1]) : ""
        let value = rawValue.first == " " ? String(rawValue.dropFirst()) : rawValue
        if field == "event" && value == "error" { isError = true }
        if field == "data" {
            eventBytes += value.utf8.count + 1
            guard eventBytes <= limit else { throw AdapterError.invalidResponse }
            dataLines.append(value)
        }
        return nil
    }
}

private enum AdapterError: LocalizedError {
    case invalidURL, invalidModel, invalidKey, emptyConversation, invalidRequest
    case unsupportedAttachment, attachmentReadFailure, unsupportedWebSearch, unsupportedThinking
    case http(Int), serverFailure, networkFailure, invalidResponse, interrupted
    case incompleteOutput, filteredOutput, unsupportedToolCall
    case busy(Int), upstreamTimeout(Int), unavailableModel(Int), quota(Int), contextLimit(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "模型地址必须是无账号、查询参数及片段的 HTTPS 基础地址。"
        case .invalidModel: "请填写有效的模型 ID，并选择 Chat Completions。"
        case .invalidKey: "请填写有效的 API Key。"
        case .emptyConversation: "请先输入消息。"
        case .invalidRequest: "请求内容过大或格式无效。"
        case .unsupportedAttachment: "附件不兼容：支持常见图片、UTF-8 文本或可提取文字的 PDF。扫描 PDF、Office 或加密文件暂不支持。"
        case .attachmentReadFailure: "附件读取失败；大小最终由设备内存与所选模型服务限制决定。"
        case .unsupportedWebSearch: "当前模型未配置网页搜索协议；请选用 OpenRouter、按服务商文档配置兼容协议，或关闭搜索。"
        case .unsupportedThinking: "自定义服务商未声明思考模式协议；请关闭深度思考。"
        case .http(let code): "模型服务返回 HTTP \(code)；请检查服务地址、模型和授权。"
        case .busy(let code): "模型服务繁忙或触发限流（HTTP \(code)），请稍后重试；本地对话已保留。"
        case .upstreamTimeout(let code): "模型服务响应超时（HTTP \(code)），请稍后重试；本地对话已保留。"
        case .unavailableModel(let code): "当前服务器模型暂不可用（HTTP \(code)），请刷新模型列表后重新选择；本地对话已保留。"
        case .quota(let code): "服务器 token 额度不足（HTTP \(code)），请检查账户额度。"
        case .contextLimit(let code): "完整对话超出模型服务的上下文限制（HTTP \(code)）；未截断或清空本地历史。"
        case .serverFailure: "模型服务报告错误，请检查服务配置。"
        case .networkFailure: "连接模型服务失败，请检查网络和服务配置。"
        case .invalidResponse: "模型服务返回了无效的流式数据。"
        case .interrupted: "模型服务中断了流式输出，请重试。"
        case .incompleteOutput: "模型输出达到长度限制，结果可能不完整。"
        case .filteredOutput: "模型服务过滤了输出。"
        case .unsupportedToolCall: "模型请求了本应用未实现的工具调用。"
        }
    }
}
