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
