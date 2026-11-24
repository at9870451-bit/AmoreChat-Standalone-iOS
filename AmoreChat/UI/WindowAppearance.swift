import SwiftUI
import UIKit

/// Set the hosting window, not each individual sheet. Unspecified restores the
/// underlying scene traits instead of holding onto the previous forced scheme.
struct WindowAppearance: UIViewRepresentable {
    let mode: AppearanceMode

    func makeUIView(context: Context) -> StyleView {
        let view = StyleView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.mode = mode
        return view
    }

    func updateUIView(_ view: StyleView, context: Context) {
        view.mode = mode
        view.applyStyle()
    }

    final class StyleView: UIView {
        var mode = AppearanceMode.system

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyStyle()
        }

        func applyStyle() {
            guard let window, window.overrideUserInterfaceStyle != mode.interfaceStyle else { return }
            window.overrideUserInterfaceStyle = mode.interfaceStyle
        }
    }
}
