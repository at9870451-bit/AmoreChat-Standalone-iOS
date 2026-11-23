import Foundation
import Observation
import Security

/// Non-secret model metadata persists locally; the API key never enters JSON or UserDefaults.
@MainActor @Observable final class ModelCatalog {
    static let shared = ModelCatalog()
    private struct Snapshot: Codable { var profiles: [ModelProfile]; var activeID: UUID? }
    private let storageKey = "standalone.modelCatalog.v1"
    private(set) var profiles: [ModelProfile] = []
    private(set) var activeID: UUID?
    var active: ModelProfile? { profiles.first(where: { $0.id == activeID }) }

    init(defaults: UserDefaults = .standard, secrets: (any ModelCredentialStore)? = nil) {
        self.defaults = defaults
        self.secrets = secrets ?? ModelSecrets()
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            profiles = saved.profiles
            activeID = saved.activeID
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any ModelCredentialStore

    func save(_ profile: ModelProfile, apiKey: String) throws {
        let label = profile.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw ModelConfigError.invalidLabel }
        guard !model.isEmpty else { throw ModelConfigError.invalidModel }
        _ = try ModelEndpoint.url(profile, suffix: "chat/completions")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { try secrets.save(key, for: profile.id) }
        else if self.apiKey(for: profile.id) == nil { throw ModelConfigError.missingKey }
        var profile = profile
        profile.label = label
        profile.modelID = model
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else { profiles.append(profile) }
        if activeID == nil { activeID = profile.id }
        persist()
    }

    func remove(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        profiles.removeAll { $0.id == id }
        secrets.remove(for: id)
        if activeID == id { activeID = profiles.first?.id }
        persist()
    }
    func select(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        persist()
    }
    func apiKey(for id: UUID) -> String? { secrets.read(for: id) }

    func fetchModels(for profile: ModelProfile, apiKey: String) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = key.isEmpty ? self.apiKey(for: profile.id) : key
        guard let credential, !credential.isEmpty else { throw ModelConfigError.missingKey }
        let url = try ModelEndpoint.url(profile, suffix: "models")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let session = URLSession(configuration: .ephemeral, delegate: ModelNoRedirect.shared, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelConfigError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ModelConfigError.http(http.statusCode) }
        guard data.count <= 2_000_000,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = payload["data"] as? [[String: Any]] else {
            throw ModelConfigError.invalidResponse
        }
        return Array(Set(values.compactMap { $0["id"] as? String }
            .filter { !$0.isEmpty && $0.count <= 200 })).sorted()
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(Snapshot(profiles: profiles, activeID: activeID)) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// Prevent cross-host redirects from forwarding the user's bearer token.
final class ModelNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ModelNoRedirect()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor private struct ModelSecrets: ModelCredentialStore {
    private let service = "app.amorechat.standalone.models"
    func read(for id: UUID) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func save(_ secret: String, for id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let value = Data(secret.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw ModelConfigError.keychain(update) }
        var item = query
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let insert = SecItemAdd(item as CFDictionary, nil)
        guard insert == errSecSuccess else { throw ModelConfigError.keychain(insert) }
    }
    func remove(for id: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
    }
}
