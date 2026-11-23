import SwiftUI
import UIKit

/// System-adaptive colors shared by the standalone chat surfaces.
enum ChatTheme {
    static let canvas = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let raised = Color(uiColor: .tertiarySystemBackground)
    static let text = Color(uiColor: .label)
    static let muted = Color(uiColor: .secondaryLabel)
    static let line = Color(uiColor: .separator)
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
