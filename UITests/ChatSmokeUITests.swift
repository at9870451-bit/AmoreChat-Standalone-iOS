import XCTest

final class ChatSmokeUITests: XCTestCase {
    func testLaunchSidebarAndOfflineGuard() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["root.sidebar.open"].waitForExistence(timeout: 20))
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 12))
        XCTAssertFalse(send.isEnabled, "Unconfigured backend must never fake a send")
        app.buttons["root.sidebar.open"].tap()
        XCTAssertTrue(app.staticTexts["Chats"].waitForExistence(timeout: 5))
        app.buttons["Close sidebar"].tap()
        XCTAssertTrue(app.buttons["root.chat.new"].waitForExistence(timeout: 5))
        app.buttons["root.chat.new"].tap()
        XCTAssertFalse(send.isEnabled)
    }
}
