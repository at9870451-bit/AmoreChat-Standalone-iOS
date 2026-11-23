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
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                                "-standalone.appearance", "dark", "-standalone.appLanguage", "zh-Hans"]
        app.launch()
        XCTAssertTrue(app.staticTexts["home.welcome"].waitForExistence(timeout: 20))
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
        XCTAssertTrue(app.buttons["settings.row.account"].exists)
        XCTAssertTrue(app.buttons["settings.row.data"].exists)
        XCTAssertTrue(app.buttons["settings.row.models"].exists)
        capture(app, name: "04-settings")
        app.buttons["settings.row.models"].tap()
        XCTAssertTrue(app.buttons["model.add.empty"].waitForExistence(timeout: 8))
        app.buttons["model.add.empty"].tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "model.editor.apiKey").firstMatch.waitForExistence(timeout: 8))
        capture(app, name: "05-add-model")
        app.buttons["model.editor.cancel"].tap()
        app.buttons["model.close"].tap()
        app.buttons["settings.close"].tap()
    }
}
