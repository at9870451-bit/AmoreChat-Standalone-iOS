import XCTest

final class ReferenceScreensUITests: XCTestCase {
    private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    func testReferenceScreensAndButtons() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.otherElements["home.welcome"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["composer.send"].isEnabled)
        capture(app, name: "01-home")

        let attach = app.buttons["composer.attach.toggle"]
        XCTAssertTrue(attach.waitForExistence(timeout: 8))
        attach.tap()
        XCTAssertTrue(app.buttons["composer.attach.camera"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["composer.attach.photos"].exists)
        XCTAssertTrue(app.buttons["composer.attach.file"].exists)
        capture(app, name: "02-attachments-expanded")
        attach.tap()
        XCTAssertFalse(app.buttons["composer.attach.camera"].exists)

        app.buttons["root.sidebar.open"].tap()
        XCTAssertTrue(app.textFields["sidebar.search"].waitForExistence(timeout: 8))
        capture(app, name: "03-history-drawer")
        app.buttons["sidebar.settings"].tap()
        XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["账户管理"].exists)
        XCTAssertTrue(app.buttons["数据管理"].exists)
        capture(app, name: "04-settings")
        app.buttons["settings.close"].tap()
    }
}
