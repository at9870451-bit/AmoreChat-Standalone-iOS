import XCTest
@testable import AmoreChatStandalone

@MainActor private final class VolatileTestSecrets: ModelCredentialStore {
    private var values: [UUID: String] = [:]
    func read(for id: UUID) -> String? { values[id] }
    func save(_ value: String, for id: UUID) throws { values[id] = value }
    func remove(for id: UUID) { values.removeValue(forKey: id) }
}

final class ModelCatalogTests: XCTestCase {
    @MainActor func testStoreSelectRemoveAndDoNotPersistSecret() throws {
        let suite = "standalone.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = ModelCatalog(defaults: defaults, secrets: VolatileTestSecrets())
        let a = ModelProfile(label: "测试直连", provider: .deepSeek,
                             modelID: "fixture-model", appendV1: false)
        let b = ModelProfile(label: "备用", provider: .openRouter,
                             modelID: "fixture-provider/model", appendV1: true)
        defer { catalog.remove(a.id); catalog.remove(b.id) }
        try catalog.save(a, apiKey: "fixture-secret-LOCAL")
        try catalog.save(b, apiKey: "fixture-secret-SECOND")
        XCTAssertEqual(catalog.activeID, a.id)
        catalog.select(b.id)
        XCTAssertEqual(catalog.active?.id, b.id)
        XCTAssertEqual(catalog.apiKey(for: b.id), "fixture-secret-SECOND")
        let snapshot = try XCTUnwrap(defaults.data(forKey: "standalone.modelCatalog.v1"))
        XCTAssertFalse(String(decoding: snapshot, as: UTF8.self).contains("fixture-secret"))
        catalog.remove(b.id)
        XCTAssertEqual(catalog.activeID, a.id)
        XCTAssertNil(catalog.apiKey(for: b.id))
    }

    @MainActor func testServerRouteMigrationKeepsProfileUUIDAndNeverSelectsByReusedID() throws {
        let suite = "server-route.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = ModelCatalog(defaults: defaults, secrets: VolatileTestSecrets())
        func remote(_ id: Int64, _ name: String, label: String = "A") -> BackendServerModel {
            BackendServerModel(id: id, label: label, model: name, provider: "fixture",
                supportsThinking: true, supportsWebSearch: false, maxOutputTokens: 4096, routeCount: 1)
        }
        catalog.activateServerModel(remote(1, "model-a"))
        let originalID = catalog.activeID
        catalog.reconcileServerModels([remote(1, "model-b", label: "B"), remote(31, "model-a")])
        XCTAssertEqual(catalog.activeID, originalID)
        XCTAssertEqual(catalog.active?.modelID, "31")
        XCTAssertEqual(catalog.active?.serverModelName, "model-a")
        XCTAssertEqual(catalog.profiles.count, 1)
        catalog.activateServerModel(remote(31, "model-a"))
        XCTAssertEqual(catalog.activeID, originalID)
        catalog.reconcileServerModels([])
        XCTAssertEqual(catalog.activeID, originalID)
        XCTAssertEqual(catalog.profiles.count, 1, "A removed route remains saved locally")
        let reloaded = ModelCatalog(defaults: defaults, secrets: VolatileTestSecrets())
        XCTAssertEqual(reloaded.activeID, originalID)
        XCTAssertEqual(reloaded.active?.serverModelName, "model-a")
    }

    @MainActor func testLegacyServerProfileDecodesWithoutSemanticName() throws {
        let suite = "server-legacy.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = ModelProfile(label: "Legacy", provider: .amoreServer,
            modelID: "1", appendV1: false)
        // The old schema had no serverModelName key at all.
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        XCTAssertNil(raw["serverModelName"])
        let snapshot = try JSONSerialization.data(withJSONObject: ["profiles": [raw], "activeID": profile.id.uuidString])
        defaults.set(snapshot, forKey: "standalone.modelCatalog.v1")
        let catalog = ModelCatalog(defaults: defaults, secrets: VolatileTestSecrets())
        XCTAssertEqual(catalog.activeID, profile.id)
        XCTAssertNil(catalog.active?.serverModelName)
        let changed = BackendServerModel(id: 31, label: "Legacy", model: "model-a", provider: "fixture",
            supportsThinking: false, supportsWebSearch: false, maxOutputTokens: 4096, routeCount: 1)
        catalog.reconcileServerModels([changed])
        XCTAssertEqual(catalog.active?.modelID, "1", "Label alone cannot infer a different numeric route")
        catalog.activateServerModel(changed)
        XCTAssertEqual(catalog.profiles.count, 2, "Explicit selection must not delete legacy configuration")
        XCTAssertEqual(catalog.active?.modelID, "31")
        XCTAssertEqual(catalog.active?.serverModelName, "model-a")
    }

    func testEndpointPathsAndHTTPSGuard() throws {
        let deepSeek = ModelProfile(label: "DeepSeek", provider: .deepSeek,
                                    modelID: "fixture", appendV1: false)
        let openRouter = ModelProfile(label: "OpenRouter", provider: .openRouter,
                                      modelID: "fixture", appendV1: true)
        XCTAssertEqual(try ModelEndpoint.url(deepSeek, suffix: "chat/completions").absoluteString,
                       "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(try ModelEndpoint.url(openRouter, suffix: "models").absoluteString,
                       "https://openrouter.ai/api/v1/models")
        let unsafe = ModelProfile(label: "unsafe", provider: .custom,
                                  baseURL: "http://example.org", modelID: "x")
        XCTAssertThrowsError(try ModelEndpoint.url(unsafe, suffix: "models"))
    }
}
