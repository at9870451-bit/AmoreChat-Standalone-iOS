import SwiftUI
import UIKit
import XCTest
@testable import AmoreChatStandalone

final class AppearanceTests: XCTestCase {
    func testPersistedModesAndUnknownFallback() throws {
        let suiteName = "standalone.appearance.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppearanceMode.storageKey, "standalone.appearance")
        XCTAssertEqual(AppearanceMode(storedValue: "unknown"), .system)
        XCTAssertEqual(AppearanceMode(storedValue: ""), .system)
        for mode in AppearanceMode.allCases {
            defaults.set(mode.rawValue, forKey: AppearanceMode.storageKey)
            let restored = AppearanceMode(storedValue: defaults.string(forKey: AppearanceMode.storageKey) ?? "system")
            XCTAssertEqual(restored, mode)
        }
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
    }

    func testCanvasAndSettingsColorsResolveUnderEffectiveTraits() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        assertWhite(ChatTheme.canvasUIColor.resolvedColor(with: light), expected: 1.0)
        assertWhite(ChatTheme.canvasUIColor.resolvedColor(with: dark), expected: 0.0588)
        assertWhite(ChatTheme.settingsBackgroundUIColor.resolvedColor(with: light), expected: 0.96)
        assertWhite(ChatTheme.settingsBackgroundUIColor.resolvedColor(with: dark), expected: 0.12)
    }

    private func assertWhite(_ color: UIColor, expected: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a), file: file, line: line)
        for component in [r, g, b] {
            XCTAssertEqual(component, expected, accuracy: 0.001, file: file, line: line)
        }
        XCTAssertEqual(a, 1.0, accuracy: 0.001, file: file, line: line)
    }
}
