import Foundation
import Security

enum BackendConfig {
    static let baseURL: URL = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String
        if let raw, let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return url
        }
        return URL(string: "https://154.12.83.231.sslip.io")!
    }()

    static func apiURL(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    static func absoluteURL(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}

struct BackendUser: Codable, Identifiable, Equatable, Sendable {
    let id: Int64
    let username: String
    let role: String
    let tokenBalance: Int64
    let inviteCode: String
    let inviteCount: Int
    let enabled: Bool
    let createdAt: String?
    let lastLoginAt: String?

    var isAdmin: Bool { role == "ADMIN" }
}

struct BackendAuthResponse: Decodable, Sendable {
    let token: String
    let expiresInSeconds: Int64
    let user: BackendUser
}

struct BackendPublicConfig: Codable, Equatable, Sendable {
    let signupTokenBonus: Int64
    let inviteTokenBonus: Int64
    let maxUploadBytes: Int64
    let maxImageBytes: Int64
    let maxHistoryMessages: Int
    let maxHistoryChars: Int
    let maxConversations: Int
    let adEnabled: Bool
    let adTitle: String
    let adLink: String
    let adImageUrl: String
}

struct BackendLedgerEntry: Decodable, Identifiable, Sendable, Equatable {
    let id: Int64
    let delta: Int64
    let balanceAfter: Int64
    let reason: String
    let reference: String
    let createdAt: String
}

struct BackendLedgerPage: Decodable, Sendable {
    let items: [BackendLedgerEntry]
    let total: Int64
    let page: Int
    let size: Int
    let balance: Int64
}

struct BackendChatMessage: Encodable, Sendable {
    let role: String
    let content: String
    let reasoning: String?
    let createdAt: String
}

struct BackendChatSyncRequest: Encodable, Sendable {
    let title: String
    let messages: [BackendChatMessage]
}

struct BackendChatSummary: Decodable, Sendable {
    let clientId: String
    let title: String
    let messageCount: Int
    let charCount: Int
    let createdAt: String
    let updatedAt: String
}

struct BackendServerModel: Decodable, Identifiable, Sendable, Equatable {
    let id: Int64
    let label: String
    let model: String
    let provider: String
    let supportsThinking: Bool
    let maxOutputTokens: Int
}

private struct BackendServerModelList: Decodable, Sendable {
    let data: [BackendServerModel]
}

enum BackendError: LocalizedError, Sendable {
    case network
    case invalidResponse
    case unauthorized
    case http(Int, String, String)

    var errorDescription: String? {
        switch self {
        case .network: return "无法连接服务器，请检查网络后重试。"
        case .invalidResponse: return "服务器返回了无法识别的内容。"
        case .unauthorized: return "登录状态已失效，请重新登录。"
        case let .http(_, code, message):
            if message.isEmpty { return "服务器错误（\(code)）" }
            return message
        }
    }

    var statusCode: Int? {
        if case .http(let status, _, _) = self { return status }
        return nil
    }

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        if case .http(let status, let code, _) = self { return status == 401 || code == "UNAUTHORIZED" }
        return false
    }
}

private struct BackendErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let code: String?
        let message: String?
    }
    let error: Detail
}

private struct BackendEmpty: Codable {}

actor BackendClient {
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession? = nil) {
        // Login bodies and bearer tokens belong only to the configured origin.
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: config, delegate: ModelNoRedirect.shared, delegateQueue: nil)
    }

    func login(username: String, password: String) async throws -> BackendAuthResponse {
        try await send("/api/v1/auth/login", method: "POST",
                       body: ["username": username, "password": password],
                       token: nil, as: BackendAuthResponse.self)
    }

    func register(username: String, password: String, inviteCode: String) async throws -> BackendAuthResponse {
        try await send("/api/v1/auth/register", method: "POST",
                       body: ["username": username, "password": password, "inviteCode": inviteCode],
                       token: nil, as: BackendAuthResponse.self)
    }

    func me(token: String) async throws -> BackendUser {
        try await send("/api/v1/auth/me", method: "GET", token: token, as: BackendUser.self)
    }

    func publicConfig() async throws -> BackendPublicConfig {
        try await send("/api/v1/public/config", method: "GET", token: nil, as: BackendPublicConfig.self)
    }

    func serverModels(token: String) async throws -> [BackendServerModel] {
        let result = try await send("/api/v1/ai/models", method: "GET", token: token,
                                    as: BackendServerModelList.self)
        return result.data
    }

    func ledger(token: String, page: Int = 0, size: Int = 20) async throws -> BackendLedgerPage {
        try await send("/api/v1/tokens/ledger?page=\(page)&size=\(size)",
                       method: "GET", token: token, as: BackendLedgerPage.self)
    }

    func syncChat(token: String, clientId: String, title: String,
                  messages: [BackendChatMessage]) async throws -> BackendChatSummary {
        let path = "/api/v1/chats/\(clientId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? clientId)"
        let body = BackendChatSyncRequest(title: title, messages: messages)
        return try await send(path, method: "PUT", body: body, token: token, as: BackendChatSummary.self)
    }

    private func send<T: Decodable>(_ path: String, method: String, token: String?,
                                    as type: T.Type) async throws -> T {
        try await send(path, method: method, body: Optional<BackendEmpty>.none, token: token, as: type)
    }

    private func send<T: Decodable, B: Encodable>(_ path: String, method: String,
                                                  body: B?, token: String?, as type: T.Type) async throws -> T {
        var request = URLRequest(url: BackendConfig.apiURL(path))
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BackendError.network
        }
        guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? decoder.decode(BackendErrorEnvelope.self, from: data)
            let code = envelope?.error.code ?? ""
            let message = envelope?.error.message ?? ""
            if http.statusCode == 401 { throw BackendError.unauthorized }
            throw BackendError.http(http.statusCode, code, message)
        }
        if T.self == BackendEmpty.self { return BackendEmpty() as! T }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BackendError.invalidResponse
        }
    }
}

enum BackendTokenKeychain {
    private static let service = "app.amorechat.standalone.backend"
    private static let account = "accessToken"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    static func save(_ token: String) throws {
        remove()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(token.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "AmoreChat.BackendAuth", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法安全保存登录状态（\(status)）"])
        }
    }

    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}