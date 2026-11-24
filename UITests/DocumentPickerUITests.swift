import XCTest

final class DocumentPickerUITests: XCTestCase {
    func testPickChatFileAndHistoryZIP() { verifyImport(useFolder: false) }
    func testLocalFolderImportsChatFileAndHistoryZIP() { verifyImport(useFolder: true) }

    private func verifyImport(useFolder: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--isolated-ui-test", "--stream-ui-test",
                                "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                                "-standalone.appearance", "dark"]
        if useFolder { app.launchArguments.append("--import-folder-ui-test") }
        app.launch()

        let toggle = app.buttons["composer.attach.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        toggle.tap()
        let files = app.buttons[useFolder ? "composer.attach.folder" : "composer.attach.file"]
        XCTAssertTrue(files.waitForExistence(timeout: 8))
        files.tap()
        if useFolder { selectFromFolder("Amore-Picker-Note.txt", in: app) }
        else { selectDocument(named: "Amore-Picker-Note", in: app) }
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
        let pick = app.buttons[useFolder ? "history.import.folder" : "history.import.pick"]
        XCTAssertTrue(pick.waitForExistence(timeout: 8))
        pick.tap()
        if useFolder { selectFromFolder("Amore-Picker-History.zip", in: app) }
        else { selectDocument(named: "Amore-Picker-History", in: app) }
        let confirm = app.buttons["history.import.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "Choosing ZIP must lead to review, not auto-import")
        capture(app, "11-import-review")
        confirm.tap()
        let result = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已导入 1 个会话")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 12))
        capture(app, "12-import-saved")
        // Pop the import page, then close data management and the settings sheet.
        app.buttons["history.import.back"].tap()
        let done = app.buttons["settings.page.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        done.tap()
        app.buttons["settings.close"].tap()
        app.buttons["root.sidebar.open"].tap()
        let imported = app.buttons.containing(NSPredicate(format: "label == %@", "Fixture")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 8))
        imported.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Hello from ZIP64-free DEFLATE")).firstMatch.waitForExistence(timeout: 8))
    }

    private func selectFromFolder(_ name: String, in app: XCUIApplication) {
        let item = app.buttons["import.folder.file.\(name)"]
        XCTAssertTrue(item.waitForExistence(timeout: 8))
        item.tap()
    }

    private func selectDocument(named name: String, in app: XCUIApplication) {
        let item = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        if !item.waitForExistence(timeout: 3) {
            let folder = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Picker Fixtures")).firstMatch
            if !folder.waitForExistence(timeout: 2) {
                let browse = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "浏览", "Browse")).firstMatch
                if browse.exists { browse.tap() }
                if !folder.waitForExistence(timeout: 2) {
                    let local = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "我的iPhone", "On My iPhone")).firstMatch
                    if local.waitForExistence(timeout: 5) { local.tap() }
                }
            }
            XCTAssertTrue(folder.waitForExistence(timeout: 8), "The test provider should be visible in Files")
            tapFileIcon(folder)
        }
        XCTAssertTrue(item.waitForExistence(timeout: 12), "The iOS Files picker must show \(name)")
        capture(app, "picker-\(name)")
        tapFileIcon(item)
    }

    private func tapFileIcon(_ item: XCUIElement) {
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: item.frame.height > 90 ? 0.22 : 0.50)).tap()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
