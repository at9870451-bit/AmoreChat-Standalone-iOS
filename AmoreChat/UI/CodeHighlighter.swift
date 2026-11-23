import Foundation
import SwiftUI
import UIKit

/// Minimal offline syntax colouring for common source and JSON replies.
/// Unsupported languages remain monospaced text, never executed.
enum CodeHighlighter {
    static func render(_ code: String, language: String) -> AttributedString {
        let result = NSMutableAttributedString(string: code)
        let full = NSRange(location: 0, length: (code as NSString).length)
        result.addAttribute(.foregroundColor, value: UIColor.label, range: full)
        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["swift", "python", "py", "javascript", "js", "typescript", "ts", "json"].contains(lang) else {
            return AttributedString(result)
        }
        func colour(_ pattern: String, _ color: UIColor) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: code, range: full) {
                result.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        let key = UIColor(red: 0.25, green: 0.44, blue: 0.83, alpha: 1)
        let literal = UIColor(red: 0.69, green: 0.30, blue: 0.42, alpha: 1)
        colour(#"\b(let|var|func|class|struct|enum|actor|import|return|if|else|for|while|guard|async|await|throws|try|def|from|with|yield|const|function|export|default|true|false|null|nil|None|True|False)\b"#, key)
        colour(#"\b\d+(\.\d+)?\b"#, UIColor(red: 0.40, green: 0.42, blue: 0.70, alpha: 1))
        colour(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, literal)
        return AttributedString(result)
    }
}
