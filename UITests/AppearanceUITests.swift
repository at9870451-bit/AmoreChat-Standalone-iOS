import CoreGraphics
import ImageIO
import XCTest

/// CI changes the simulated OS appearance with simctl ui before running each phase.
/// Read actual screen pixels rather than relying on XCTest's device appearance cache.
final class AppearanceUITests: XCTestCase {
    func testAgainstDarkSystem() throws { try verifyAppearance(systemDark: true) }
    func testAgainstLightSystem() throws { try verifyAppearance(systemDark: false) }

    private func verifyAppearance(systemDark: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--isolated-ui-test", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        openSettings(app)
        // Set the opposite style using the real menu, not a launch preference.
        let forced = systemDark ? "light" : "dark"
        try select(forced, label: systemDark ? "浅色" : "深色", in: app)
        try verifyBackground(in: app, dark: !systemDark, name: "settings-forced-\(forced)")
        app.buttons["settings.close"].tap()
        try verifyBackground(in: app, dark: !systemDark, name: "chat-forced-\(forced)")
        app.terminate()
        app.launch()
        try verifyBackground(in: app, dark: !systemDark, name: "chat-relaunch-forced-\(forced)")
        openSettings(app)
        try select("system", label: "系统", in: app)
        let expected = systemDark ? "dark" : "light"
        try verifyBackground(in: app, dark: systemDark, name: "settings-follow-system-\(expected)")
        app.buttons["settings.close"].tap()
        try verifyBackground(in: app, dark: systemDark, name: "chat-follow-system-\(expected)")
    }

    private func openSettings(_ app: XCUIApplication) {
        let sidebar = app.buttons["root.sidebar.open"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 20))
        sidebar.tap()
        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        XCTAssertTrue(app.buttons["settings.row.appearance"].waitForExistence(timeout: 8))
    }

    private func select(_ mode: String, label: String, in app: XCUIApplication) throws {
        let row = app.buttons["settings.row.appearance"]
        row.tap()
        let identifier = app.buttons["settings.appearance.\(mode)"]
        let option = identifier.waitForExistence(timeout: 3) ? identifier : app.buttons[label].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 8))
        option.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", label), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed)
    }

    private func verifyBackground(in app: XCUIApplication, dark: Bool, name: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(8)
        var last = [UInt8]()
        repeat {
            let shot = app.screenshot()
            last = try backgroundPixel(in: shot)
            if last.allSatisfy({ dark ? $0 < 65 : $0 > 210 }) {
                let attachment = XCTAttachment(screenshot: shot)
                attachment.name = name + "-rgb-" + last.map { String($0) }.joined(separator: "-")
                attachment.lifetime = .keepAlways
                add(attachment)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        XCTFail("\(name): expected \(dark ? "dark" : "light"), sampled RGB \(last)", file: file, line: line)
    }

    private func backgroundPixel(in shot: XCUIScreenshot) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(shot.pngRepresentation as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let area = CGRect(x: Int(Double(image.width) * 0.025), y: Int(Double(image.height) * 0.53), width: 1, height: 1)
        let onePixel = try XCTUnwrap(image.cropping(to: area))
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                              CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(onePixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        XCTAssertTrue(drawn)
        return Array(rgba.prefix(3))
    }
}
