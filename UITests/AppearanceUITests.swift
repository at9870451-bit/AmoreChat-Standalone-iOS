import CoreGraphics
import ImageIO
import XCTest

/// Run on an iOS Simulator. A real screenshot pixel (not just a selection label)
/// verifies each mode on the nested sheet, settings sheet, and chat canvas.
final class AppearanceUITests: XCTestCase {
    func testLightDarkSystemAndPersistedSelection() throws {
        let device = XCUIDevice.shared
        let originalAppearance = device.appearance
        defer { device.appearance = originalAppearance }
        device.appearance = .dark

        let app = XCUIApplication()
        // Do not pass -standalone.appearance: launch overrides would mask persistence.
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        openSettings(app)

        try select("light", title: "浅色", dark: false, in: app)
        app.buttons["settings.close"].tap()
        try verifyBackground(in: app, dark: false, name: "01-chat-forced-light")

        // Relaunch with the device still dark: the user's light preference survives.
        app.terminate()
        app.launch()
        try verifyBackground(in: app, dark: false, name: "02-chat-light-after-relaunch")
        // Opposite OS style makes a forced dark style observable too.
        device.appearance = .light
        openSettings(app)
        try select("dark", title: "深色", dark: true, in: app)
        app.buttons["settings.close"].tap()
        try verifyBackground(in: app, dark: true, name: "03-chat-forced-dark")

        openSettings(app)
        try select("system", title: "系统", dark: false, in: app)
        app.buttons["settings.close"].tap()
        try verifyBackground(in: app, dark: false, name: "04-chat-system-light")

        // System mode must respond while EACH presentation stays open.
        openSettings(app)
        let appearanceRow = app.buttons["settings.row.appearance"]
        XCTAssertTrue(appearanceRow.label.contains("系统"))
        try verifyBackground(in: app, dark: false, name: "05-settings-system-light")
        appearanceRow.tap()
        XCTAssertTrue(app.buttons["settings.appearance.system"].isSelected)
        try verifyBackground(in: app, dark: false, name: "06-selector-system-light")
        device.appearance = .dark
        try verifyBackground(in: app, dark: true, name: "07-selector-system-dark")
        app.buttons["settings.appearance.done"].tap()
        try verifyBackground(in: app, dark: true, name: "08-settings-system-dark")
        app.buttons["settings.close"].tap()
        try verifyBackground(in: app, dark: true, name: "09-chat-system-dark")
        device.appearance = .light
        try verifyBackground(in: app, dark: false, name: "10-chat-system-light-again")

        // The stored system choice must continue following the device on relaunch.
        device.appearance = .dark
        app.terminate()
        app.launch()
        try verifyBackground(in: app, dark: true, name: "11-system-dark-after-relaunch")
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

    private func select(_ mode: String, title: String, dark: Bool,
                        in app: XCUIApplication) throws {
        app.buttons["settings.row.appearance"].tap()
        let option = app.buttons["settings.appearance.\(mode)"]
        XCTAssertTrue(option.waitForExistence(timeout: 8))
        option.tap()  // No context menu or popover may intercept this tap.
        XCTAssertTrue(option.isSelected, "The selected option must be announced to VoiceOver")
        try verifyBackground(in: app, dark: dark, name: "selector-\(mode)")
        app.buttons["settings.appearance.done"].tap()
        let row = app.buttons["settings.row.appearance"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(row.label.contains(title), "Stored setting must update the summary row")
        try verifyBackground(in: app, dark: dark, name: "settings-\(mode)")
    }

    private struct RGB {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    private func verifyBackground(in app: XCUIApplication, dark: Bool,
                                  name: String, file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(8)
        var last = RGB(red: 0, green: 0, blue: 0)
        repeat {
            let screenshot = app.screenshot()
            // 3% from the left, halfway down: outside the card/text/safe-area.
            last = try backgroundPixel(in: screenshot)
            let components = [last.red, last.green, last.blue]
            if components.allSatisfy({ dark ? $0 < 65 : $0 > 210 }) {
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = name + "-rgb-\(last.red)-\(last.green)-\(last.blue)"
                attachment.lifetime = .keepAlways
                add(attachment)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        XCTFail("\(name): expected \(dark ? "dark" : "light") background, " +
                "sampled RGB (\(last.red), \(last.green), \(last.blue))", file: file, line: line)
    }

    private func backgroundPixel(in screenshot: XCUIScreenshot) throws -> RGB {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let x = Int(Double(image.width) * 0.03)
        let y = Int(Double(image.height) * 0.50)
        let onePixel = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
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
        XCTAssertTrue(drawn, "The screenshot must be readable as an RGBA pixel")
        return RGB(red: rgba[0], green: rgba[1], blue: rgba[2])
    }
}
