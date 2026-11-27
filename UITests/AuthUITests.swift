import XCTest

final class AuthUITests: XCTestCase {
    private enum Mode: Int {
        case login, register
        var identifier: String { self == .login ? "auth.mode.login" : "auth.mode.register" }
    }

    // Synthetic local input only. Never tap auth.submit or type a Return/newline:
    // --signed-out-ui-test forces the gate, but does not stub login/register requests.
    private let fixtureUsername = "auth_ui_only"
    private let fixturePassword = "UITest42"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testFirstLaunchRequiresAccountAndCapturesLogin() {
        let app = launchSignedOut()
        let brand = app.staticTexts["auth.brand"]
        XCTAssertTrue(brand.waitForExistence(timeout: 5))
        XCTAssertEqual(brand.label, "AmoreChat")
        XCTAssertTrue(modeButton(.login, in: app).exists)
        XCTAssertTrue(modeButton(.register, in: app).exists)
        assertEmpty(app.textFields["auth.username"])
        let password = app.secureTextFields["auth.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        assertEmpty(password)
        XCTAssertFalse(app.textFields["auth.password"].exists, "Passwords must start hidden")
        XCTAssertFalse(app.textFields["auth.invite"].exists, "First launch must show login, not registration")
        expectSubmit(false, in: app)
        XCTAssertFalse(app.buttons["root.sidebar.open"].exists, "Chat must stay gated without an account")
        capture(app, name: "auth-01-login")
    }

    func testRegistrationRequiresInviteAndModeSwitchClearsPassword() {
        let app = launchSignedOut()
        selectMode(.register, in: app)
        let invite = app.textFields["auth.invite"]
        XCTAssertTrue(invite.waitForExistence(timeout: 5), "Registration must expose auth.invite")
        assertEmpty(invite)
        expectSubmit(false, in: app)
        capture(app, name: "auth-02-register")

        enter(fixtureUsername, into: app.textFields["auth.username"])
        enter(fixturePassword, into: app.secureTextFields["auth.password"])
        expectSubmit(false, in: app) // Valid account/password cannot bypass the required invite.
        enter("UI000", into: invite)
        expectSubmit(false, in: app) // Five characters are still too short.
        invite.typeText("1")
        expectSubmit(true, in: app) // Six synthetic characters; observe only, never submit.
        assertSubmitReachableWithKeyboard(in: app, focusedField: invite)
        capture(app, name: "auth-03-register-keyboard")

        selectMode(.login, in: app)
        XCTAssertFalse(invite.exists)
        XCTAssertTrue(app.secureTextFields["auth.password"].waitForExistence(timeout: 5))
        assertEmpty(app.secureTextFields["auth.password"])
        expectSubmit(false, in: app)

        enter(fixturePassword, into: app.secureTextFields["auth.password"])
        expectSubmit(true, in: app)
        selectMode(.register, in: app)
        XCTAssertTrue(invite.waitForExistence(timeout: 5))
        assertEmpty(invite)
        assertEmpty(app.secureTextFields["auth.password"])
        expectSubmit(false, in: app) // Both directions must discard the previous password.
    }

    func testPasswordVisibilityPreservesValueAndSubmitIsReachableWithKeyboard() {
        let app = launchSignedOut()
        enter(fixtureUsername, into: app.textFields["auth.username"])
        let hidden = app.secureTextFields["auth.password"]
        enter("UITest4", into: hidden)
        expectSubmit(false, in: app) // Seven characters must not enable login.
        hidden.typeText("2")
        expectSubmit(true, in: app)

        let toggle = app.buttons["auth.password.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        let visible = app.textFields["auth.password"]
        XCTAssertTrue(visible.waitForExistence(timeout: 5))
        XCTAssertFalse(hidden.exists)
        XCTAssertTrue(visible.value as? String == fixturePassword, "Showing a password must preserve its value")
        toggle.tap()
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
        XCTAssertFalse(visible.exists)
        toggle.tap()
        XCTAssertTrue(visible.waitForExistence(timeout: 5))
        XCTAssertTrue(visible.value as? String == fixturePassword, "A hide/show round trip must not lose the value")
        toggle.tap()
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
        XCTAssertFalse(visible.exists)
        expectSubmit(true, in: app)
        hidden.tap()
        assertSubmitReachableWithKeyboard(in: app, focusedField: hidden)
        capture(app, name: "auth-04-login-keyboard")
    }

    private func launchSignedOut() -> XCUIApplication {
        let app = XCUIApplication()
        // Keep the device language; selectors never depend on translated Chinese labels.
        app.launchArguments = ["--signed-out-ui-test", "-standalone.appearance", "dark"]
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.textFields["auth.username"].waitForExistence(timeout: 20))
        return app
    }

    private func modeButton(_ mode: Mode, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[mode.identifier]
        if button.waitForExistence(timeout: 2) { return button }
        // Retain native Picker support without depending on localized segment titles.
        let picker = app.segmentedControls["auth.mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Missing auth mode buttons or auth.mode Picker")
        XCTAssertEqual(picker.buttons.count, 2, "Expected login then register segments")
        return picker.buttons.element(boundBy: mode.rawValue)
    }

    private func selectMode(_ mode: Mode, in app: XCUIApplication) {
        let button = modeButton(mode, in: app)
        for _ in 0..<4 {
            if button.isHittable { break }
            app.scrollViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(button.isHittable, "The requested auth mode must be accessible")
        button.tap()
    }

    private func enter(_ text: String, into field: XCUIElement) {
        XCTAssertFalse(text.contains("\n") || text.contains("\r"), "Fixtures must never submit via the keyboard")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    private func assertEmpty(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.exists, file: file, line: line)
        let value = field.value as? String
        XCTAssertTrue(value == "" || (field.placeholderValue != nil && value == field.placeholderValue),
                      "The field must be empty, not contain a previous value", file: file, line: line)
    }

    private func expectSubmit(_ enabled: Bool, in app: XCUIApplication,
                              file: StaticString = #filePath, line: UInt = #line) {
        let submit = app.buttons["auth.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5), file: file, line: line)
        let state = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == %@", NSNumber(value: enabled)), object: submit)
        XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: 5), .completed,
                       "auth.submit must be \(enabled ? "enabled" : "disabled")", file: file, line: line)
    }

    private func assertSubmitReachableWithKeyboard(in app: XCUIApplication, focusedField: XCUIElement) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "This check requires the software keyboard")
        let submit = app.buttons["auth.submit"]
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        for _ in 0..<4 {
            let viewport = scroll.frame.intersection(app.frame)
            if submit.isHittable && viewport.contains(submit.frame)
                && submit.frame.maxY <= keyboard.frame.minY { break }
            let top = viewport.minY + 12
            let bottom = min(viewport.maxY, keyboard.frame.minY) - 12
            XCTAssertGreaterThan(bottom, top, "A scrollable area must remain above the keyboard")
            // Drag in the side gutter, never on the enabled submit button or keyboard.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = viewport.minX - app.frame.minX + 6
            let start = origin.withOffset(CGVector(dx: x, dy: bottom - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: x, dy: top - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
            // Interactive scroll dismissal is allowed, but the final assertion must
            // still exercise a visible keyboard, not an easier dismissed-keyboard state.
            if !keyboard.exists {
                focusedField.tap()
                XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            }
        }
        XCTAssertTrue(keyboard.exists)
        XCTAssertTrue(submit.isEnabled)
        XCTAssertTrue(submit.isHittable, "Primary action must remain reachable without submitting")
        XCTAssertTrue(scroll.frame.intersection(app.frame).contains(submit.frame),
                      "Primary action must be fully inside the viewport")
        XCTAssertLessThanOrEqual(submit.frame.maxY, keyboard.frame.minY, "Keyboard must not cover the primary action")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
