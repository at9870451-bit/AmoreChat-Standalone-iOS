import XCTest
@testable import AmoreChatStandalone

final class BackendAPITests: XCTestCase {
    func testPublicConfigDecodingAndUploadLimits() throws {
        let json = """
        {"signupTokenBonus":5000000,"inviteTokenBonus":5000000,"maxUploadBytes":26214400,
         "maxImageBytes":10485760,"maxHistoryMessages":2000,"maxHistoryChars":2000000,
         "maxConversations":200,"adEnabled":true,"adTitle":"活动","adLink":"https://example.com",
         "adImageUrl":"/api/v1/public/ad-image/abc.png"}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(BackendPublicConfig.self, from: json)
        XCTAssertEqual(config.signupTokenBonus, 5_000_000)
        XCTAssertEqual(config.inviteTokenBonus, 5_000_000)
        XCTAssertTrue(config.adEnabled)
        let limits = BackendUploadLimits(config)
        XCTAssertEqual(limits.fileBytes, 26_214_400)
        XCTAssertEqual(limits.imageBytes, 10_485_760)
        XCTAssertEqual(limits.historyMessages, 2000)
    }

    func testBackendConfigUsesHTTPSOrigin() {
        XCTAssertEqual(BackendConfig.baseURL.scheme, "https")
        XCTAssertEqual(BackendConfig.apiURL("/api/v1/public/health").host, BackendConfig.baseURL.host)
        XCTAssertEqual(BackendConfig.absoluteURL("/api/v1/public/ad-image/a.png")?.scheme, "https")
    }

    func testTokenCompactionNeverInventsDecimals() {
        XCTAssertEqual(BackendAuthStore.tokenText(5_000_000), "5,000,000")
        XCTAssertEqual(BackendAuthStore.compactTokenText(5_000_000), "500.00 万")
    }
}