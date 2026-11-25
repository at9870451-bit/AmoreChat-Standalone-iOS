import XCTest

final class AuthUITests: XCTestCase {
    func testFirstLaunchRequiresAccountAndRegisterInvite() {
        let app = XCUIApplication()
        app.launchArguments.append("--signed-out-ui-test")
        app.launch()

        let username = app.descendants(matching: .any)
            .matching(identifier: "auth.username").firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["root.sidebar.open"].exists, "Chat must not open before account login")

        let submit = app.buttons["auth.submit"]
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled, "Empty form must not submit")

        let segmented = app.segmentedControls.firstMatch
        XCTAssertTrue(segmented.waitForExistence(timeout: 5))
        segmented.buttons["注册"].tap()

        let invite = app.descendants(matching: .any)
            .matching(identifier: "auth.invite").firstMatch
        XCTAssertTrue(invite.waitForExistence(timeout: 5), "Registration must expose an invite-code field")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "邀请码")).firstMatch.exists)
    }
}