import Foundation

/// Metadata only. API keys are never encoded into this type or UserDefaults.
enum ModelProvider: String, Codable, CaseIterable, Sendable {
    case deepSeek, openAI, openRouter, custom, amoreServer

    var displayName: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .custom: "OpenAI 兼容接口"
        case .amoreServer: "AmoreChat 服务器 API"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepSeek: "https://api.deepseek.com"
        case .openAI: "https://api.openai.com"
        case .openRouter: "https://openrouter.ai/api"
        case .custom: ""
        case .amoreServer: BackendConfig.apiURL("api/v1/ai").absoluteString
        }
    }
    var defaultAppendV1: Bool { self == .openAI || self == .openRouter }
    var isServer: Bool { self == .amoreServer }
    static var editorCases: [ModelProvider] { [.deepSeek, .openAI, .openRouter, .custom] }
}

enum ModelAPIFormat: String, Codable, CaseIterable, Sendable {
    case chatCompletions
    var displayName: String { "Chat Completions" }
}

enum CompatibleThinking: String, Codable, CaseIterable, Sendable {
    case deepSeekSwitch, reasoningEffort, openRouterReasoning

    var displayName: String {
        switch self {
        case .deepSeekSwitch: "DeepSeek：thinking.type"
        case .reasoningEffort: "OpenAI：reasoning_effort"
        case .openRouterReasoning: "OpenRouter：reasoning.enabled"
        }
    }
}

struct ModelProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var label: String
    var provider: ModelProvider
    var baseURL: String
    var modelID: String
    var appendV1: Bool
    var format: ModelAPIFormat
    var compatibleThinking: CompatibleThinking? = nil
    var compatibleWebSearch: Bool? = nil
    /// Stable semantic identity for server routes whose numeric IDs can change.
    /// Optional so old local catalogs still decode; never used as a chat/session ID.
    var serverModelName: String? = nil

    private var apiHost: String? {
        guard let url = try? ModelEndpoint.root(baseURL, appendV1: appendV1),
              url.port == nil || url.port == 443 else { return nil }
        return url.host?.lowercased()
    }

    var thinkingProtocol: CompatibleThinking? {
        switch provider {
        case .deepSeek where apiHost == "api.deepseek.com": .deepSeekSwitch
        case .openAI where apiHost == "api.openai.com": .reasoningEffort
        case .openRouter where apiHost == "openrouter.ai": .openRouterReasoning
        case .custom: compatibleThinking
        case .amoreServer: compatibleThinking
        default: nil
        }
    }

    var allowsThinking: Bool { thinkingProtocol != nil }

    var allowsWebSearch: Bool {
        if provider == .amoreServer { return compatibleWebSearch == true }
        guard let url = try? ModelEndpoint.root(baseURL, appendV1: appendV1) else { return false }
        if provider == .custom { return compatibleWebSearch == true }
        return provider == .openRouter && apiHost == "openrouter.ai"
            && url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "api/v1"
    }

    init(id: UUID = UUID(), label: String = "", provider: ModelProvider = .deepSeek,
         baseURL: String = "", modelID: String = "", appendV1: Bool = false,
         format: ModelAPIFormat = .chatCompletions) {
        self.id = id
        self.label = label
        self.provider = provider
        self.baseURL = baseURL.isEmpty && provider != .custom ? provider.defaultBaseURL : baseURL
        self.modelID = modelID
        self.appendV1 = appendV1
        self.format = format
    }
}

enum ModelConfigError: LocalizedError {
    case invalidURL, invalidModel, invalidLabel, missingKey, http(Int), invalidResponse, keychain(Int32)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入有效的 HTTPS 服务地址，不能包含账号、密码、查询参数或片段。"
        case .invalidModel: "请输入真实的模型 ID。"
        case .invalidLabel: "请输入服务商备注名称。"
        case .missingKey: "请填写 API Key，密钥只保存在 iOS 钥匙串。"
        case .http(let status): "模型服务返回 HTTP \(status)，请核对地址、密钥和账号权限。"
        case .invalidResponse: "模型列表响应格式无效。"
        case .keychain(let code): "iOS 钥匙串不可用（OSStatus \(code)），未保存此配置。"
        }
    }
}

/// HTTPS only; avoids cleartext credential exposure, query-userinfo leakage,
/// redirected base-URL surprises, and the need for broad ATS exceptions.
enum ModelEndpoint {
    static func root(_ text: String, appendV1: Bool) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else { throw ModelConfigError.invalidURL }
        var path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if appendV1 && path.split(separator: "/").last?.lowercased() != "v1" {
            path += path.isEmpty ? "v1" : "/v1"
        }
        var target = URLComponents()
        target.scheme = "https"
        target.host = host
        target.port = components.port
        target.path = "/" + path
        guard let result = target.url else { throw ModelConfigError.invalidURL }
        return result
    }
    static func url(_ profile: ModelProfile, suffix: String) throws -> URL {
        let base = try root(profile.baseURL, appendV1: profile.appendV1)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let prefix = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = "/" + (prefix.isEmpty ? "" : prefix + "/")
            + suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = components?.url else { throw ModelConfigError.invalidURL }
        return url
    }
}
