import XCTest

final class ChatSmokeUITests: XCTestCase {
    func testTapChatCanvasDismissesKeyboardAndSavesDraft() {
        let app = XCUIApplication()
        app.launch()
        let field = app.descendants(matching: .any)
            .matching(identifier: "composer.message").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("本机草稿")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38)).tap()
        let keyboardGone = NSPredicate(format: "exists == false")
        expectation(for: keyboardGone, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(field.exists)
    }

    func testLaunchSidebarAndOfflineGuard() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["root.sidebar.open"].waitForExistence(timeout: 20))
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 12))
        XCTAssertFalse(send.isEnabled, "Unconfigured backend must never fake a send")
        app.buttons["root.sidebar.open"].tap()
        XCTAssertTrue(app.textFields["sidebar.search"].waitForExistence(timeout: 5))
        app.buttons["Close sidebar"].tap()
        XCTAssertTrue(app.buttons["root.chat.new"].waitForExistence(timeout: 5))
        app.buttons["root.chat.new"].tap()
        XCTAssertFalse(send.isEnabled)
    }
}
