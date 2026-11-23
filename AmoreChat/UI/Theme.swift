import SwiftUI
import UIKit

/// System-adaptive colors shared by the standalone chat surfaces.
enum ChatTheme {
    static let canvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.0588, alpha: 1) : .white })
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
