import XCTest

final class DocumentPickerUITests: XCTestCase {
    func testPickChatFileAndHistoryZIP() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--isolated-ui-test", "--stream-ui-test", "--document-ui-test",
                                "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                                "-standalone.appearance", "dark"]
        app.launch()

        let toggle = app.buttons["composer.attach.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        toggle.tap()
        let files = app.buttons["composer.attach.file"]
        XCTAssertTrue(files.waitForExistence(timeout: 8))
        files.tap()
        selectDocument(named: "Amore-Picker-Note", in: app)
        let remove = app.buttons["composer.attachment.remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 20), "The selected file must be copied into the draft")
        let voice = app.buttons["composer.speech"]
        let send = app.buttons["composer.send"]
        XCTAssertTrue(voice.exists && send.isEnabled)
        XCTAssertLessThan(toggle.frame.midX, voice.frame.midX)
        XCTAssertLessThan(voice.frame.midX, send.frame.midX)
        capture(app, "10-selected-file")
        XCTAssertTrue(app.staticTexts["home.welcome"].exists, "Picking a file must not send it")
        let prompt = app.buttons["composer.attachment.prompt"].firstMatch
        XCTAssertTrue(prompt.exists)
        prompt.tap()
        XCTAssertTrue(app.staticTexts["home.welcome"].exists, "Attachment prompts must not auto-send")

        app.buttons["root.sidebar.open"].tap()
        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        let data = app.buttons["settings.row.data"]
        XCTAssertTrue(data.waitForExistence(timeout: 8))
        data.tap()
        let open = app.descendants(matching: .any)["history.import.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        open.tap()
        let pick = app.buttons["history.import.pick"]
        XCTAssertTrue(pick.waitForExistence(timeout: 8))
        pick.tap()
        selectDocument(named: "Amore-Picker-History", in: app)
        let confirm = app.buttons["history.import.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "Choosing ZIP must lead to review, not auto-import")
        capture(app, "11-import-review")
        confirm.tap()
        let result = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已导入 1 个会话")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 12))
        capture(app, "12-import-saved")
        // Close data management and verify the imported conversation is visible in history.
        app.buttons["settings.page.done"].tap()
        app.buttons["settings.close"].tap()
        app.buttons["root.sidebar.open"].tap()
        let imported = app.buttons.containing(NSPredicate(format: "label == %@", "Fixture")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 8))
        imported.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Hello from ZIP64-free DEFLATE")).firstMatch.waitForExistence(timeout: 8))
    }

    private func selectDocument(named name: String, in app: XCUIApplication) {
        let picker = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        let predicate = NSPredicate(format: "label BEGINSWITH %@", name)
        let remoteItem = app.descendants(matching: .any).matching(predicate).firstMatch
        let filesItem = picker.descendants(matching: .any).matching(predicate).firstMatch
        if remoteItem.waitForExistence(timeout: 10) { remoteItem.tap(); return }
        XCTAssertTrue(filesItem.waitForExistence(timeout: 8), "The real iOS Files picker must expose \(name)")
        filesItem.tap()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
