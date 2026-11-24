import Foundation
import CryptoKit
import CoreFoundation

/// Strictly importable, lossless *text + reasoning* subset of DeepSeek official export v3.
/// Incompatible fragments, attachments and statuses fail the WHOLE archive, never disappear silently.
enum DeepSeekImportError: LocalizedError {
    case invalidZIP, encryptedZIP, unsafeArchive(String), unsupportedFormat(String), invalidData(String)
    var errorDescription: String? {
        switch self {
        case .invalidZIP: return "ZIP 已损坏或校验失败（CRC / 文件头 / 大小）。未导入任何会话。"
        case .encryptedZIP: return "不支持加密的 ZIP；请在 DeepSeek 重新导出未加密的历史记录。"
        case .unsafeArchive(let message): return "ZIP 不安全：\(message)。未导入任何会话。"
        case .unsupportedFormat(let message): return "不支持此 DeepSeek 导出：\(message)。未导入任何会话。"
        case .invalidData(let message): return "导出文件内容不完整：\(message)。未导入任何会话。"
        }
    }
}

struct DeepSeekImportResult: Sendable {
    let sessions: [ChatSession]
    let sourceSessionCount: Int
    let messageCount: Int // total across imported branches (may duplicate shared ancestor messages)
    let branchCount: Int

    /// Compare deterministic IDs; no writes. Parent must save the merged snapshot atomically
    /// BEFORE publishing it to ChatController (and must cancel pending controller saves).
    func merging(into existing: [ChatSession]) -> (sessions: [ChatSession], added: Int, duplicates: Int) {
        let known = Set(existing.map(\.id))
        let added = sessions.filter { !known.contains($0.id) }
        return (existing + added, added.count, sessions.count - added.count)
    }
}

enum DeepSeekImport {
    /// Parses every archive entry and verifies CRCs before returning; no session is persisted here.
    /// Official reference: https://github.com/deepseek-ai/chat-demo/blob/main/src/services/chat/history/README.md
    static func parse(_ url: URL) throws -> DeepSeekImportResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let zip = try DeepSeekImportZIP(url: url)
        guard let manifestEntry = zip.entries.first(where: { $0.path == "manifest.json" }),
              let indexEntry = zip.entries.first(where: { $0.path == "chat_session_index.json" }) else {
            throw DeepSeekImportError.unsupportedFormat("缺少清单或会话索引；不支持其他导出版式")
        }
        let manifest = try dictionary(zip.read(manifestEntry), manifestEntry.path)
        guard let version = integer(manifest["export_format_version"]), version == 3 else {
            throw DeepSeekImportError.unsupportedFormat("仅支持 export_format_version = 3")
        }
        guard let index = try? JSONSerialization.jsonObject(with: zip.read(indexEntry)) as? [[String: Any]] else {
            throw DeepSeekImportError.invalidData("会话索引格式错误")
        }
        var rawSessions = [String: [String: Any]]()
        var expected = Set<String>()
        let namespace = "" // Never read account fields into the session store.
        for entry in zip.entries where entry.path != manifestEntry.path && entry.path != indexEntry.path {
            let data = try zip.read(entry)
            if entry.path == "user.json" {
                _ = try dictionary(data, entry.path) // validate but never retain profile data
            } else if entry.path.hasPrefix("chat_sessions/"), entry.path.hasSuffix(".json"),
                      !entry.path.dropFirst("chat_sessions/".count).contains("/") {
                let path = String(entry.path.dropFirst("chat_sessions/".count).dropLast(5))
                guard !path.isEmpty, !path.contains("/"), !path.contains("\\"), path != ".", path != ".." else {
                    throw DeepSeekImportError.unsafeArchive("非法会话路径")
                }
                let value = try dictionary(data, entry.path)
                guard let id = value["id"] as? String, id == path, rawSessions[id] == nil else {
                    throw DeepSeekImportError.invalidData("会话 ID 与文件名不一致或重复")
                }
                rawSessions[id] = value
                expected.insert(id)
            } else if entry.path.hasPrefix("chat_sessions/"), entry.path.contains("_files/") {
                throw DeepSeekImportError.unsupportedFormat("含附件原件；当前只支持纯文字与思考")
            } else {
                throw DeepSeekImportError.unsupportedFormat("含未知格式条目")
            }
        }
        let sessionCount = rawSessions.count
        guard index.count == sessionCount else {
            throw DeepSeekImportError.invalidData("索引和会话文件数量不一致")
        }
        var sessions = [ChatSession](), ids = Set<String>(), messages = 0
        var textBytes = 0
        for item in index {
            try Task.checkCancellation()
            guard let id = item["id"] as? String, ids.insert(id).inserted,
                  let source = rawSessions[id],
                  let rawMessages = source["messages"] as? [Any],
                  item["message_count"].map({ integer($0) == rawMessages.count }) ?? true,
                  let inserted = date(item["inserted_at"]),
                  let updated = date(item["updated_at"]),
                  inserted == date(source["inserted_at"]),
                  source["updated_at"].map({ date($0) == updated }) ?? true else {
                throw DeepSeekImportError.invalidData("索引与会话内容不一致")
            }
            let branches = try parseSession(source, namespace: namespace, updated: updated,
                                            pinned: item["pinned"] as? Bool ?? source["pinned"] as? Bool ?? false)
            guard sessions.count + branches.count <= 4_096 else {
                throw DeepSeekImportError.unsafeArchive("分支过多（上限 4096）")
            }
            for branch in branches {
                messages += branch.messages.count
                for message in branch.messages {
                    textBytes += message.content.utf8.count + (message.reasoning?.utf8.count ?? 0)
                }
                guard messages <= 50_000, textBytes <= 24 * 1_024 * 1_024 else {
                    throw DeepSeekImportError.unsafeArchive("分支展开后消息过多或文字超过 24 MiB")
                }
            }
            sessions.append(contentsOf: branches)
        }
        guard ids == expected else { throw DeepSeekImportError.invalidData("索引遗漏会话") }
        return DeepSeekImportResult(sessions: sessions, sourceSessionCount: sessionCount,
                                    messageCount: messages, branchCount: sessions.count - sessionCount)
    }

    private struct Node {
        let id: Int
        let parent: Int?
        let message: ChatMessage
    }

    private static func parseSession(_ source: [String: Any], namespace: String, updated: Date,
                                     pinned: Bool) throws -> [ChatSession] {
        guard let id = source["id"] as? String, !id.isEmpty,
              let rawTitle = source["title"], (rawTitle is NSNull || rawTitle is String),
              let raw = source["messages"] as? [[String: Any]], raw.count <= 5_000,
              let created = date(source["inserted_at"]) else {
            throw DeepSeekImportError.invalidData("会话元数据无效")
        }
        let title = (rawTitle as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "新对话"
        var nodes = [Int: Node](), children = [Int: [Int]]()
        for message in raw {
            guard let nodeID = integer(message["id"]), nodeID >= 0, nodes[nodeID] == nil,
                  let roleString = message["role"] as? String,
                  let role = ChatRole(rawValue: roleString.lowercased()),
                  let status = message["status"] as? String, status == "FINISHED",
                  let when = date(message["inserted_at"]),
                  let fragments = message["fragments"] as? [[String: Any]] else {
                throw DeepSeekImportError.unsupportedFormat("会话 \(id) 包含未知角色、状态或错误消息")
            }
            let parent: Int?
            if message["parent_id"] is NSNull { parent = nil }
            else if let value = integer(message["parent_id"]), value >= 0 && value < nodeID { parent = value }
            else { throw DeepSeekImportError.invalidData("会话 \(id) 中的父消息 ID 无效") }
            if let parent {
                guard let old = nodes[parent], old.message.role != role else {
                    throw DeepSeekImportError.invalidData("会话 \(id) 消息父节点缺失或角色不交替")
                }
                children[parent, default: []].append(nodeID)
            } else if role != .user { throw DeepSeekImportError.invalidData("根消息不是用户提问") }
            var content = "", reasoning = ""
            var elapsed: TimeInterval?
            for fragment in fragments {
                guard let kind = fragment["type"] as? String,
                      ["REQUEST", "RESPONSE", "THINK"].contains(kind),
                      let text = fragment["content"] as? String else {
                    throw DeepSeekImportError.unsupportedFormat("会话 \(id) 有附件、模板、工具片段或未知内容；目前仅支持文字和思考")
                }
                guard kind == "THINK" ? role == .assistant : (kind == "REQUEST" ? role == .user : role == .assistant) else {
                    throw DeepSeekImportError.invalidData("会话 \(id) 消息与片段角色不一致")
                }
                if kind == "THINK" {
                    reasoning += text
                    if let seconds = fragment["elapsed_secs"] as? NSNumber,
                       CFGetTypeID(seconds) != CFBooleanGetTypeID(), seconds.doubleValue.isFinite,
                       seconds.doubleValue >= 0, seconds.doubleValue <= 86_400 {
                        elapsed = min(86_400, (elapsed ?? 0) + seconds.doubleValue)
                    }
                } else { content += text }
            }
            var parsed = ChatMessage(id: stableUUID("msg|\(namespace)|\(id)|\(nodeID)"),
                                     role: role, content: content,
                                     reasoning: reasoning.isEmpty ? nil : reasoning,
                                     createdAt: when, status: .complete)
            parsed.reasoningDuration = elapsed
            nodes[nodeID] = Node(id: nodeID, parent: parent, message: parsed)
        }
        if raw.isEmpty {
            return [ChatSession(id: stableUUID("chat|\(namespace)|\(id)|empty"), title: title,
                                createdAt: created, updatedAt: updated, isPinned: pinned)]
        }
        let storedCurrent = integer(source["current_message_id"])
        guard let current = storedCurrent.flatMap({ nodes[$0] == nil ? nil : $0 }) ?? nodes.keys.max() else {
            throw DeepSeekImportError.invalidData("缺少可读消息节点")
        }
        // Preserve ALL alternative branches as separately labeled linear chats, plus the current
        // path when it ends before a leaf. ChatSession cannot represent a native message tree.
        let endpoints = [current] + nodes.keys.filter {
            $0 != current && children[$0, default: []].isEmpty
        }.sorted()
        guard endpoints.count <= 256 else { throw DeepSeekImportError.unsafeArchive("单会话分支过多") }
        var result = [ChatSession]()
        for endpoint in endpoints {
            var path = [ChatMessage](), seen = Set<Int>(), at: Int? = endpoint
            while let next = at {
                guard seen.insert(next).inserted, let node = nodes[next] else {
                    throw DeepSeekImportError.invalidData("循环或丢失消息")
                }
                path.append(node.message); at = node.parent
            }
            path.reverse()
            let label = endpoints.count > 1 && endpoint != current ? "（分支 \(endpoint)）" : ""
            result.append(ChatSession(id: stableUUID("chat|\(namespace)|\(id)|\(endpoint)"),
                                      title: String((title + label).prefix(100)), createdAt: created,
                                      updatedAt: updated, isPinned: pinned && endpoint == current, messages: path))
        }
        return result
    }

    private static func dictionary(_ data: Data, _ name: String) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeepSeekImportError.invalidData("\(name) 不是 JSON 对象")
        }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= Double(Int.max), number.doubleValue.rounded() == number.doubleValue else {
            return nil
        }
        return number.intValue
    }

    private static func title(_ value: Any?) throws -> String {
        if value is NSNull { return "新对话" }
        guard let string = value as? String else { throw DeepSeekImportError.invalidData("会话标题不是文字或 null") }
        return string.isEmpty ? "新对话" : string
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let parts = text.dropLast().split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.isLenient = false
        guard let base = formatter.date(from: String(parts[0]) + "Z"),
              formatter.string(from: base) == String(parts[0]) + "Z" else { return nil }
        if parts.count == 1 { return base }
        guard let fraction = Double("0." + String(parts[1])), fraction.isFinite else { return nil }
        return base.addingTimeInterval(fraction)
    }

    private static func stableUUID(_ source: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("AmoreChat:DeepSeek:v3:" + source).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
