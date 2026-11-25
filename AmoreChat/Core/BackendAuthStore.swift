import Foundation
import Observation

@MainActor
@Observable
final class BackendAuthStore {
    enum Phase: Equatable {
        case checking
        case signedOut
        case signedIn
    }

    private(set) var phase: Phase = .checking
    private(set) var user: BackendUser?
    private(set) var publicConfig: BackendPublicConfig?
    private(set) var ledger: BackendLedgerPage?
    private(set) var doingNetworkWork = false
    private(set) var errorText: String?
    private(set) var ledgerError: String?
    private(set) var isTestMode = false
    @ObservationIgnored private let client = BackendClient()
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var forcedSignedOut = false

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--signed-out-ui-test") {
            forcedSignedOut = true
            phase = .signedOut
            return
        }
        if arguments.contains("--isolated-ui-test") || arguments.contains("--ui-test-bypass-auth") {
            isTestMode = true
            phase = .signedIn
            accessToken = nil
            user = BackendUser(id: 1, username: "uitest", role: "USER",
                               tokenBalance: 5_000_000, inviteCode: "UITEST0001",
                               inviteCount: 0, enabled: true,
                               createdAt: nil, lastLoginAt: nil)
            publicConfig = BackendPublicConfig(signupTokenBonus: 5_000_000,
                                               inviteTokenBonus: 5_000_000,
                                               maxUploadBytes: 25 * 1024 * 1024,
                                               maxImageBytes: 10 * 1024 * 1024,
                                               maxHistoryMessages: 2000,
                                               maxHistoryChars: 2_000_000,
                                               maxConversations: 200,
                                               adEnabled: false, adTitle: "", adLink: "",
                                               adImageUrl: "")
        }
        #endif
    }

    var isSignedIn: Bool { phase == .signedIn }

    var displayUsername: String { user?.username ?? "" }

    func start() async {
        guard !isTestMode, !forcedSignedOut, !started else { return }
        started = true
        errorText = nil
        Task { await loadPublicConfig() }
        guard let stored = BackendTokenKeychain.load() else {
            phase = .signedOut
            return
        }
        do {
            let profile = try await client.me(token: stored)
            accessToken = stored
            user = profile
            phase = .signedIn
        } catch let error as BackendError where error.isUnauthorized {
            BackendTokenKeychain.remove()
            accessToken = nil
            phase = .signedOut
        } catch {
            phase = .signedOut
            errorText = (error as? LocalizedError)?.errorDescription ?? "暂时无法连接服务器，请重试。"
        }
    }

    func retryConnection() async {
        guard !isTestMode else { return }
        phase = .checking
        started = false
        await start()
    }

    func login(username: String, password: String) async {
        guard !isTestMode, !doingNetworkWork else { return }
        errorText = nil
        doingNetworkWork = true
        defer { doingNetworkWork = false }
        do {
            let response = try await client.login(username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  password: password)
            try completeAuthentication(response)
        } catch {
            errorText = userMessage(error)
        }
    }

    func register(username: String, password: String, inviteCode: String) async {
        guard !isTestMode, !doingNetworkWork else { return }
        errorText = nil
        doingNetworkWork = true
        defer { doingNetworkWork = false }
        do {
            let response = try await client.register(username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                                     password: password,
                                                     inviteCode: inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            try completeAuthentication(response)
        } catch {
            errorText = userMessage(error)
        }
    }

    private func completeAuthentication(_ response: BackendAuthResponse) throws {
        try BackendTokenKeychain.save(response.token)
        accessToken = response.token
        user = response.user
        phase = .signedIn
        errorText = nil
        Task { await loadPublicConfig() }
    }

    func logout() {
        BackendTokenKeychain.remove()
        accessToken = nil
        user = nil
        ledger = nil
        ledgerError = nil
        phase = .signedOut
        errorText = nil
    }

    func refreshUser() async {
        guard let token = accessToken else { return }
        do {
            user = try await client.me(token: token)
            errorText = nil
        } catch let error as BackendError where error.isUnauthorized {
            logout()
        } catch {
            errorText = userMessage(error)
        }
    }

    func loadPublicConfig() async {
        guard !isTestMode || publicConfig == nil else { return }
        do {
            publicConfig = try await client.publicConfig()
        } catch {
            // Login may still succeed while optional discovery data is unavailable.
        }
    }

    func loadLedger() async {
        guard let token = accessToken else {
            ledgerError = isTestMode ? "当前为界面测试模式，没有真实云端账户。" : nil
            return
        }
        doingNetworkWork = true
        defer { doingNetworkWork = false }
        do {
            ledger = try await client.ledger(token: token, page: 0, size: 20)
            if let balance = ledger?.balance {
                user = user.map {
                    BackendUser(id: $0.id, username: $0.username, role: $0.role,
                                tokenBalance: balance, inviteCode: $0.inviteCode,
                                inviteCount: $0.inviteCount, enabled: $0.enabled,
                                createdAt: $0.createdAt, lastLoginAt: $0.lastLoginAt)
                }
            }
            ledgerError = nil
        } catch let error as BackendError where error.isUnauthorized {
            logout()
        } catch {
            ledgerError = userMessage(error)
        }
    }

    func syncCurrentSession(_ session: ChatSession) async throws -> BackendChatSummary {
        guard let token = accessToken else {
            throw BackendError.unauthorized
        }
        let messages = session.messages
            .filter { $0.status != .streaming && ($0.content.isEmpty == false || ($0.reasoning ?? "").isEmpty == false) }
            .map { message in
                BackendChatMessage(role: message.role == .user ? "user" : "assistant",
                                   content: message.content,
                                   reasoning: message.reasoning?.isEmpty == true ? nil : message.reasoning,
                                   createdAt: Self.isoString(message.createdAt))
            }
        do {
            let result = try await client.syncChat(token: token, clientId: session.id.uuidString,
                                                   title: session.title, messages: messages)
            await refreshUser()
            return result
        } catch let error as BackendError where error.isUnauthorized {
            logout()
            throw error
        }
    }

    nonisolated static func tokenText(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    nonisolated static func compactTokenText(_ value: Int64) -> String {
        if value >= 100_000_000 { return String(format: "%.2f 亿", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "%.2f 万", Double(value) / 10_000) }
        return "\(value)"
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func userMessage(_ error: Error) -> String {
        if let backend = error as? BackendError { return backend.errorDescription ?? "请求失败" }
        return (error as? LocalizedError)?.errorDescription ?? "请求失败"
    }
}

struct BackendUploadLimits: Equatable, Sendable {
    let fileBytes: Int64
    let imageBytes: Int64
    let historyMessages: Int
    let historyChars: Int
    let conversations: Int

    static let fallback = BackendUploadLimits(fileBytes: 8 * 1024 * 1024,
                                              imageBytes: 10 * 1024 * 1024,
                                              historyMessages: 2000,
                                              historyChars: 2_000_000,
                                              conversations: 200)

    init(fileBytes: Int64, imageBytes: Int64, historyMessages: Int, historyChars: Int, conversations: Int) {
        self.fileBytes = max(1_024, min(fileBytes, 64 * 1024 * 1024))
        self.imageBytes = max(1_024, min(imageBytes, 32 * 1024 * 1024))
        self.historyMessages = max(1, historyMessages)
        self.historyChars = max(1, historyChars)
        self.conversations = max(1, conversations)
    }

    init(_ config: BackendPublicConfig) {
        self.init(fileBytes: config.maxUploadBytes, imageBytes: config.maxImageBytes,
                  historyMessages: config.maxHistoryMessages, historyChars: config.maxHistoryChars,
                  conversations: config.maxConversations)
    }
}