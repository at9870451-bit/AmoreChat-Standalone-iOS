import SwiftUI
import UIKit

/// The values match the existing `standalone.appearance` UserDefaults setting.
/// Unknown/old values behave like "system" without forcing an interface style.
enum AppearanceMode: String, CaseIterable, Identifiable {
    static let storageKey = "standalone.appearance"

    case system, light, dark

    var id: String { rawValue }

    init(storedValue: String) {
        self = Self(rawValue: storedValue) ?? .system
    }

    var displayName: String {
        switch self {
        case .system: "系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Retained for compatibility with view layout and theme tests.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// UIColor's dynamic providers resolve against the *effective* traits of each
/// presentation. Do not resolve these colors once using the device's system style:
/// SwiftUI can explicitly override the style of the root view or a sheet.
enum ChatTheme {
    static let canvasUIColor = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.0588, alpha: 1) : .white }
    static let canvas = Color(uiColor: canvasUIColor)

    static let settingsBackgroundUIColor = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.96, alpha: 1) }
    static let settingsBackground = Color(uiColor: settingsBackgroundUIColor)
    static let drawerPreview = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.116, alpha: 1) : UIColor(white: 0.959, alpha: 1) })

    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.1529, alpha: 1) : UIColor(white: 0.9686, alpha: 1) })
    static let raised = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.2, alpha: 1) : UIColor(white: 0.9255, alpha: 1) })
    static let text = Color(uiColor: .label)
    static let muted = Color(uiColor: .secondaryLabel)
    static let line = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.2588, alpha: 1) : UIColor(white: 0.851, alpha: 1) })
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.48, green: 0.65, blue: 0.99, alpha: 1)
            : UIColor(red: 0.20, green: 0.39, blue: 0.84, alpha: 1)
    })
    static let accentWash = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.13, green: 0.20, blue: 0.34, alpha: 1)
            : UIColor(red: 0.91, green: 0.95, blue: 1.00, alpha: 1)
    })
    static let danger = Color(uiColor: .systemRed)
    static let radius: CGFloat = 16
}
