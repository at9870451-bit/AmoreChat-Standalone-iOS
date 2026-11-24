import XCTest

final class ConversationUITests: XCTestCase {
    func testReplyLayoutVoicePadAndIndependentStop() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--isolated-ui-test", "--stream-ui-test", "-AppleLanguages", "(zh-Hans)",
                                "-AppleLocale", "zh_CN", "-standalone.appearance", "dark"]
        app.launch()
        let speech = app.buttons["composer.speech"]
        XCTAssertTrue(speech.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["11"].exists)
        XCTAssertFalse(app.buttons["root.model.select"].exists, "An empty chat must not show the model label")
        speech.tap()
        XCTAssertTrue(app.staticTexts["composer.speech.hold"].waitForExistence(timeout: 8))
        capture(app, "06-voice-mode")
        app.buttons["composer.keyboard"].tap()
        type("你好", app)
        app.buttons["composer.send"].tap()
        let thinking = app.buttons["message.reasoning"].firstMatch
        XCTAssertTrue(thinking.waitForExistence(timeout: 15))
        let answer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "用于模拟器验收的回复")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["重新生成"].firstMatch.waitForExistence(timeout: 8))
        capture(app, "07-chat-collapsed")
        app.buttons["root.sidebar.open"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.session.menu.")).firstMatch.waitForExistence(timeout: 8))
        capture(app, "15-sidebar-selected")
        app.buttons["root.sidebar.close"].tap()
        thinking.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "仅供模拟器测试的思考内容")).firstMatch.waitForExistence(timeout: 8))
        capture(app, "08-chat-expanded")

        type("stop fixture", app)
        app.buttons["composer.send"].tap()
        let stop = app.buttons["composer.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        let plus = app.buttons["composer.attach.toggle"]
        XCTAssertTrue(plus.exists && speech.exists)
        XCTAssertEqual(plus.frame.midY, stop.frame.midY, accuracy: 3)
        XCTAssertEqual(speech.frame.midY, stop.frame.midY, accuracy: 3)
        XCTAssertLessThan(plus.frame.midX, speech.frame.midX)
        XCTAssertLessThan(speech.frame.midX, stop.frame.midX)
        XCTAssertFalse(app.buttons["composer.send"].exists)
        capture(app, "09-stop-and-voice")
        stop.tap()
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stop)
        XCTAssertEqual(XCTWaiter.wait(for: [ended], timeout: 12), .completed)
        XCTAssertTrue(speech.isEnabled)
    }

    func testModesReflectTapsAndReachSelectedModel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--isolated-ui-test", "--stream-ui-test", "-AppleLanguages", "(zh-Hans)",
                                "-AppleLocale", "zh_CN", "-standalone.appearance", "dark"]
        app.launch()
        let thinking = app.buttons["composer.mode.thinking"]
        let search = app.buttons["composer.mode.search"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 20))
        XCTAssertEqual(thinking.value as? String, "已关闭")
        XCTAssertEqual(search.value as? String, "已关闭")
        capture(app, "13-modes-off")
        thinking.tap()
        XCTAssertEqual(thinking.value as? String, "已开启")
        search.tap()
        app.alerts.buttons["开启联网搜索"].tap()
        XCTAssertEqual(search.value as? String, "已开启")
        capture(app, "14-modes-on")
        type("options fixture", app)
        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "思考开／搜索开")).firstMatch.waitForExistence(timeout: 15))
        thinking.tap()
        search.tap()
        XCTAssertEqual(thinking.value as? String, "已关闭")
        XCTAssertEqual(search.value as? String, "已关闭")
        type("options fixture", app)
        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "思考关／搜索关")).firstMatch.waitForExistence(timeout: 15))
    }

    private func type(_ text: String, _ app: XCUIApplication) {
        let field = app.descendants(matching: .any).matching(identifier: "composer.message").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText(text)
        XCTAssertTrue(app.buttons["composer.send"].waitForExistence(timeout: 8))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
