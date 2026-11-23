import SwiftUI
import UIKit
import WebKit

/// A deliberately small, offline Markdown renderer; unsupported LaTeX remains readable.
struct RichTextView: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { item in
                switch item.element {
                case .prose(let text): prose(text)
                case .code(let language, let code): codeBlock(language, code)
                case .table(let rows): table(rows)
                case .math(let formula): formulaView(formula, display: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Block { case prose(String), code(String, String), table([[String]]), math(String) }
    private var blocks: [Block] {
        let lines = source.components(separatedBy: "\n")
        var result: [Block] = [], paragraph: [String] = [], index = 0
        func flush() {
            if !paragraph.isEmpty { result.append(.prose(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush(); let fence = String(trimmed.prefix(3)), language = String(trimmed.dropFirst(3))
                index += 1; var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index]); index += 1
                }
                result.append(.code(language, code.joined(separator: "\n")))
                if index < lines.count { index += 1 }
            } else if index + 1 < lines.count, line.contains("|"), isRule(lines[index + 1]) {
                flush(); var rows = [cells(line)]; index += 2
                while index < lines.count && lines[index].contains("|") {
                    rows.append(cells(lines[index])); index += 1
                }
                result.append(.table(rows))
            } else if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                flush(); let opener = trimmed.hasPrefix("$$") ? "$$" : "\\["
                let closer = opener == "$$" ? "$$" : "\\]"
                var math = String(trimmed.dropFirst(opener.count)); index += 1
                while !math.hasSuffix(closer) && index < lines.count {
                    math += "\n" + lines[index]; index += 1
                }
                if math.hasSuffix(closer) { math = String(math.dropLast(closer.count)) }
                result.append(.math(math.trimmingCharacters(in: .whitespacesAndNewlines)))
            } else { paragraph.append(line); index += 1 }
        }
        flush(); return result
    }

    private func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private func isRule(_ line: String) -> Bool {
        let columns = cells(line)
        return !columns.isEmpty && columns.allSatisfy {
            let value = $0.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "")
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }
    @ViewBuilder private func prose(_ text: String) -> some View {
        let pattern = #"(?<!\\)\$([^$\n]+)\$|\\\((.+?)\\\)"#
        let regex = try? NSRegularExpression(pattern: pattern)
        ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { item in
            let line = item.element
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let regex, regex.firstMatch(in: line, range: range) != nil {
                formulaView(line, display: false)
            } else if !line.isEmpty {
                Text((try? AttributedString(markdown: line)) ?? AttributedString(line))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else { Spacer(minLength: 4).frame(height: 4) }
        }
    }
    private func codeBlock(_ language: String, _ code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { UIPasteboard.general.string = code } label: { Label("复制代码", systemImage: "doc.on.doc").labelStyle(.iconOnly) }
                    .accessibilityLabel("复制代码")
            }.padding(.horizontal, 12).padding(.vertical, 8)
            ScrollView(.horizontal) {
                Text(CodeHighlighter.render(code, language: language))
                    .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false).padding(12)
            }
        }.background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func table(_ rows: [[String]]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<(rows.map(\.count).max() ?? 0), id: \.self) { column in
                            let cell = column < rows[row].count ? rows[row][column] : ""
                            Text((try? AttributedString(markdown: cell)) ?? AttributedString(cell))
                                .font(.subheadline).frame(minWidth: 70, alignment: .leading)
                                .padding(9).background(row == 0 ? ChatTheme.accentWash : ChatTheme.surface)
                                .overlay(alignment: .bottom) { ChatTheme.line.frame(height: 0.5) }
                        }
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 10))
        }.accessibilityLabel("表格，共\(rows.count)行")
    }
    @ViewBuilder private func formulaView(_ input: String, display: Bool) -> some View {
        if let html = MathMarkup.html(input, display: display) {
            MathWebView(html: html).frame(height: display ? 72 : 42)
                .accessibilityLabel("数学公式：\(input)")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("公式源码（此语法暂不支持）").font(.caption).foregroundStyle(.secondary)
                Text(input).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            }.padding(10).background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct MathWebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        view.loadHTMLString(html, baseURL: nil)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastHTML = "" }
}

/// Only a documented subset is converted. No remote assets, scripts, or raw HTML enter the view.
private enum MathMarkup {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    static func html(_ input: String, display: Bool) -> String? {
        let regex = try? NSRegularExpression(pattern: #"(?<!\\)\$([^$\n]+)\$|\\\((.+?)\\\)"#)
        let rendered: String
        if display {
            var parser = Parser(input)
            guard let math = parser.parse() else { return nil }
            rendered = "<math display='block' xmlns='http://www.w3.org/1998/Math/MathML'>\(math)</math>"
        } else {
            let range = NSRange(input.startIndex..<input.endIndex, in: input)
            guard let matches = regex?.matches(in: input, range: range), !matches.isEmpty else { return nil }
            var output = "", start = input.startIndex
            for match in matches {
                guard let full = Range(match.range, in: input) else { return nil }
                output += escape(String(input[start..<full.lowerBound]))
                let group = match.range(at: 1).location == NSNotFound ? 2 : 1
                guard let expression = Range(match.range(at: group), in: input) else { return nil }
                var parser = Parser(String(input[expression]))
                guard let math = parser.parse() else { return nil }
                output += "<math xmlns='http://www.w3.org/1998/Math/MathML'>\(math)</math>"
                start = full.upperBound
            }
            rendered = output + escape(String(input[start...]))
        }
        return """
        <!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>
        <meta http-equiv='Content-Security-Policy' content="default-src 'none'; style-src 'unsafe-inline'">
        <style>html,body{margin:0;background:transparent;color:#29262a;font:17px -apple-system,BlinkMacSystemFont,sans-serif}
        @media(prefers-color-scheme:dark){html,body{color:#f3eff1}}body{padding:7px 2px}math{vertical-align:middle}</style>
        </head><body>\(rendered)</body></html>
        """
    }
    private struct Parser {
        let symbols = ["alpha":"α", "beta":"β", "gamma":"γ", "theta":"θ", "lambda":"λ", "mu":"μ",
                       "sigma":"σ", "omega":"ω", "pi":"π", "infty":"∞", "times":"×", "cdot":"·",
                       "pm":"±", "leq":"≤", "geq":"≥", "neq":"≠", "sum":"∑", "int":"∫"]
        let chars: [Character]; var index = 0; var depth = 0
        init(_ input: String) { chars = Array(input) }
        mutating func parse() -> String? {
            guard !chars.isEmpty, chars.count <= 300, let result = sequence(), index == chars.count else { return nil }
            return result
        }
        mutating func sequence(until close: Character? = nil) -> String? {
            depth += 1; defer { depth -= 1 }
            guard depth <= 12 else { return nil }
            var result = ""
            while index < chars.count && chars[index] != close {
                guard var atom = element() else { return nil }
                var sub: String?, sup: String?
                while index < chars.count && (chars[index] == "_" || chars[index] == "^") {
                    let script = chars[index]; index += 1
                    guard let value = argument() else { return nil }
                    if script == "_" { sub = value } else { sup = value }
                }
                if let sub, let sup { atom = "<msubsup>\(atom)\(sub)\(sup)</msubsup>" }
                else if let sub { atom = "<msub>\(atom)\(sub)</msub>" }
                else if let sup { atom = "<msup>\(atom)\(sup)</msup>" }
                result += atom
            }
            if let close { guard index < chars.count && chars[index] == close else { return nil }; index += 1 }
            return "<mrow>\(result)</mrow>"
        }
        mutating func argument() -> String? {
            guard index < chars.count else { return nil }
            if chars[index] == "{" { index += 1; return sequence(until: "}") }
            return element()
        }
        mutating func element() -> String? {
            guard index < chars.count else { return nil }
            let char = chars[index]; index += 1
            if char == "{" { return sequence(until: "}") }
            if char == "\\" {
                let start = index
                while index < chars.count && chars[index].isLetter { index += 1 }
                let command = String(chars[start..<index])
                if command == "frac", let a = argument(), let b = argument() { return "<mfrac>\(a)\(b)</mfrac>" }
                if command == "sqrt", let a = argument() { return "<msqrt>\(a)</msqrt>" }
                if let value = symbols[command] { return "<mo>\(value)</mo>" }
                return nil
            }
            if char == "}" || char == "^" || char == "_" || char == "$" { return nil }
            if char.isWhitespace { return "<mspace width='0.3em'/>" }
            let tag = char.isNumber ? "mn" : char.isLetter ? "mi" : "mo"
            return "<\(tag)>\(MathMarkup.escape(String(char)))</\(tag)>"
        }
    }
}
