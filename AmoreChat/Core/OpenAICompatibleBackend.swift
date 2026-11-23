import Foundation

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
    var supportsWebSearch: Bool {
        profile.provider == .openRouter &&
        URLComponents(string: profile.baseURL)?.host?.lowercased() == "openrouter.ai"
    }

    func stream(messages: [ChatMessage], options: ChatOptions) async throws -> AsyncThrowingStream<BackendChunk, Error> {
        try Task.checkCancellation()
        let url = try endpoint()
        guard !apiKey.isEmpty, apiKey == apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw AdapterError.invalidKey }
        guard !messages.isEmpty else { throw AdapterError.emptyConversation }
        guard !options.webSearch || supportsWebSearch else { throw AdapterError.unsupportedWebSearch }
        guard !options.deepThinking || profile.provider != .custom else { throw AdapterError.unsupportedThinking }
        let body = try requestBody(messages: messages, options: options)
        try Task.checkCancellation()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
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

    private func requestBody(messages: [ChatMessage], options: ChatOptions) throws -> Data {
        var payload: [String: Any] = [
            "model": profile.modelID,
            "stream": true,
            "messages": try messages.map(encodeMessage)
        ]
        switch profile.provider {
        case .deepSeek:
            // https://api-docs.deepseek.com/guides/thinking_mode (OpenAI format)
            payload["thinking"] = ["type": options.deepThinking ? "enabled" : "disabled"]
        case .openAI:
            // Only opt in; some OpenAI models do not accept reasoning_effort.
            if options.deepThinking { payload["reasoning_effort"] = "high" }
        case .openRouter:
            // https://openrouter.ai/docs/guides/best-practices/reasoning-tokens
            if options.deepThinking { payload["reasoning"] = ["enabled": true] }
            if options.webSearch { payload["plugins"] = [["id": "web"]] }
        case .custom:
            break // No provider-specific fields without an explicit contract.
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload), body.count <= 12 * 1_024 * 1_024
        else { throw AdapterError.invalidRequest }
        return body
    }

    private func encodeMessage(_ message: ChatMessage) throws -> [String: Any] {
        var result: [String: Any] = ["role": message.role.rawValue]
        if message.role == .assistant {
            guard message.attachments.isEmpty else { throw AdapterError.unsupportedAttachment }
            result["content"] = message.content
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                if profile.provider == .deepSeek { result["reasoning_content"] = reasoning }
                if profile.provider == .openRouter { result["reasoning"] = reasoning }
            }
            return result
        }
        var text = message.content
        var images = [[String: Any]]()
        var totalBytes = 0
        for attachment in message.attachments {
            try Task.checkCancellation()
            guard attachment.localURL.isFileURL else { throw AdapterError.unsupportedAttachment }
            let mime = attachment.type.lowercased()
            let imageTypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif"]
            let textTypes: Set<String> = ["text/plain", "text/markdown", "text/csv", "text/xml", "application/json", "application/xml", "text/x-python", "text/x-yaml"]
            guard imageTypes.contains(mime) || textTypes.contains(mime) else { throw AdapterError.unsupportedAttachment }
            // Check the file size before allocating memory, then check again against races.
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: attachment.localURL.path),
                  let size = attributes[.size] as? NSNumber, size.int64Value >= 0,
                  size.int64Value <= 8 * 1_024 * 1_024,
                  totalBytes + size.intValue <= 8 * 1_024 * 1_024,
                  let bytes = try? Data(contentsOf: attachment.localURL, options: .mappedIfSafe),
                  !bytes.isEmpty, bytes.count <= 8 * 1_024 * 1_024,
                  totalBytes + bytes.count <= 8 * 1_024 * 1_024
            else { throw AdapterError.attachmentReadFailure }
            totalBytes += bytes.count
            if imageTypes.contains(mime) {
                guard Self.matchesImageSignature(bytes, mime: mime) else { throw AdapterError.unsupportedAttachment }
                images.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(bytes.base64EncodedString())"]])
            } else {
                guard let content = String(data: bytes, encoding: .utf8), !content.contains("\0")
                else { throw AdapterError.unsupportedAttachment }
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
        guard (200...299).contains(http.statusCode) else { throw AdapterError.http(http.statusCode) }
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

    var errorDescription: String? {
        switch self {
        case .invalidURL: "模型地址必须是无账号、查询参数及片段的 HTTPS 基础地址。"
        case .invalidModel: "请填写有效的模型 ID，并选择 Chat Completions。"
        case .invalidKey: "请填写有效的 API Key。"
        case .emptyConversation: "请先输入消息。"
        case .invalidRequest: "请求内容过大或格式无效。"
        case .unsupportedAttachment: "附件格式不受支持：仅可发送 JPEG、PNG、WebP、GIF 和 UTF-8 文本。"
        case .attachmentReadFailure: "附件读取失败或超过 8 MB 总限制。"
        case .unsupportedWebSearch: "当前服务商不支持网页搜索；请选用 OpenRouter 或关闭搜索。"
        case .unsupportedThinking: "自定义服务商未声明思考模式协议；请关闭深度思考。"
        case .http(let code): "模型服务返回 HTTP \(code)；请检查服务地址、模型和授权。"
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
