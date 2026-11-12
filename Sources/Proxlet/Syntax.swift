//
//  Syntax.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import AppKit
import ProxletCore
import SwiftUI

/// Token colors shared by the flow detail and both editors, editable in `theme.json`.
struct Theme: Codable, Equatable {
    struct Palette: Codable, Equatable {
        var key: String
        var string: String
        var number: String
        var literal: String
        var keyword: String
        var comment: String
        var statusLine: String
        var headerName: String
        var headerValue: String
        /// `{ } [ ]` colors by nesting depth, cycling.
        var brackets: [String]
        /// JS function names (`foo(`) and declaration/literal words (`var`, `function`, `true`).
        var function: String
        var storage: String
    }

    var light: Palette
    var dark: Palette

    // Dark+ / Light+ palette.
    static let `default` = Theme(
        light: Palette(key: "#0451A5", string: "#A31515", number: "#098658", literal: "#0000FF", keyword: "#AF00DB",
                       comment: "#008000", statusLine: "#0000FF", headerName: "#0451A5", headerValue: "#A31515",
                       brackets: ["#0431FA", "#319331", "#7B3814"], function: "#795E26", storage: "#0000FF"),
        dark: Palette(key: "#9CDCFE", string: "#CE9178", number: "#B5CEA8", literal: "#569CD6", keyword: "#C586C0",
                      comment: "#6A9955", statusLine: "#569CD6", headerName: "#9CDCFE", headerValue: "#CE9178",
                      brackets: ["#FFD700", "#DA70D6", "#179FFF"], function: "#DCDCAA", storage: "#569CD6")
    )

    static var file: URL { Paths.root.appendingPathComponent("theme.json") }
    private static var cache: (modified: Date, theme: Theme)?

    /// Current theme; writes the default file on first use and re-reads it when it changes.
    static var current: Theme {
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? nil
        guard let modified else {
            write(.default)
            return .default
        }
        if let cache, cache.modified == modified { return cache.theme }
        // A file that doesn't decode (hand-edited, missing a key) uses the default palette.
        let theme = (try? JSONDecoder().decode(Theme.self, from: Data(contentsOf: file))) ?? .default
        cache = (modified, theme)
        return theme
    }

    private static func write(_ theme: Theme) {
        try? Paths.ensure()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(theme).write(to: file)
    }

    func palette(dark isDark: Bool) -> Palette { isDark ? dark : light }
}

enum SyntaxKind {
    case json, http, javascript
}

enum Token: Equatable {
    case key, string, number, literal, keyword, comment, statusLine, headerName, headerValue, function, storage
    /// Bracket at nesting depth (0 = outermost).
    case bracket(Int)

    /// Palette color for this token (one case per kind); nil leaves the default text color.
    func hex(in p: Theme.Palette) -> String? { // swiftlint:disable:this cyclomatic_complexity
        switch self {
        case .function: p.function
        case .storage: p.storage
        case .bracket(let depth):
            p.brackets.isEmpty ? nil : p.brackets[depth % p.brackets.count]
        case .key: p.key
        case .string: p.string
        case .number: p.number
        case .literal: p.literal
        case .keyword: p.keyword
        case .comment: p.comment
        case .statusLine: p.statusLine
        case .headerName: p.headerName
        case .headerValue: p.headerValue
        }
    }
}

enum Syntax {
    // Highlighting is skipped above this size to keep typing and scrolling responsive.
    static let maxLength = 300_000

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Only called with the literal patterns below; a typo fails every Syntax test at once.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let jsonString = rx(#""(?:[^"\\\n]|\\.)*""#)
    private static let jsonKey = rx(#""(?:[^"\\\n]|\\.)*"(?=\s*:)"#)
    private static let number = rx(#"(?<![\w.])-?(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#)
    private static let jsonLiteral = rx(#"\b(?:true|false|null)\b"#)
    private static let jsString = rx(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`"#)
    private static let jsKeyword = rx(#"\b(?:return|if|else|for|while|do|switch|case|default|break|continue|try|catch|finally"#
        + #"|throw|new|typeof|instanceof|in|of|delete|void|yield|await|async)\b"#)
    private static let jsStorage = rx(#"\b(?:var|let|const|function|class|extends|this|true|false|null|undefined|NaN|Infinity)\b"#)
    private static let jsFunction = rx(#"\b[A-Za-z_$][\w$]*(?=\s*\()"#)
    private static let jsComment = rx(#"//[^\n]*|/\*[\s\S]*?\*/"#)

    /// Colored spans; later spans win over earlier ones where they overlap.
    static func spans(_ text: String, kind: SyntaxKind) -> [(NSRange, Token)] {
        let ns = text as NSString
        guard ns.length <= maxLength else { return [] }
        switch kind {
        case .json: return json(ns, in: NSRange(location: 0, length: ns.length))
        case .javascript:
            let all = NSRange(location: 0, length: ns.length)
            // Later spans win: strings and comments override anything that looked like code inside them.
            return jsBrackets(ns) + match(jsFunction, ns, all, .function) + match(number, ns, all, .number)
                + match(jsStorage, ns, all, .storage) + match(jsKeyword, ns, all, .keyword)
                + match(jsString, ns, all, .string) + match(jsComment, ns, all, .comment)
        case .http: return http(ns)
        }
    }

    private static func match(_ re: NSRegularExpression, _ ns: NSString, _ range: NSRange, _ token: Token) -> [(NSRange, Token)] {
        re.matches(in: ns as String, range: range).map { ($0.range, token) }
    }

    private static func json(_ ns: NSString, in range: NSRange) -> [(NSRange, Token)] {
        brackets(ns, in: range) + match(number, ns, range, .number) + match(jsonLiteral, ns, range, .literal)
            + match(jsonString, ns, range, .string) + match(jsonKey, ns, range, .key)
    }

    /// `( ) { } [ ]` outside JS strings and comments, tagged with their nesting depth.
    private static func jsBrackets(_ ns: NSString) -> [(NSRange, Token)] {
        var out: [(NSRange, Token)] = []
        var depth = 0
        var i = 0
        let n = ns.length
        while i < n {
            let c = ns.character(at: i)
            let next = i + 1 < n ? ns.character(at: i + 1) : 0
            switch c {
            case 0x22, 0x27, 0x60:  // " ' `
                i += 1
                while i < n, ns.character(at: i) != c { i += ns.character(at: i) == 0x5C ? 2 : 1 }
            case 0x2F where next == 0x2F:  // //
                while i < n, ns.character(at: i) != 0x0A { i += 1 }
            case 0x2F where next == 0x2A:  // /*
                i += 2
                while i + 1 < n, !(ns.character(at: i) == 0x2A && ns.character(at: i + 1) == 0x2F) { i += 1 }
                i += 1
            case 0x28, 0x7B, 0x5B:  // ( { [
                out.append((NSRange(location: i, length: 1), .bracket(depth)))
                depth += 1
            case 0x29, 0x7D, 0x5D:  // ) } ]
                depth = max(depth - 1, 0)
                out.append((NSRange(location: i, length: 1), .bracket(depth)))
            default: break
            }
            i += 1
        }
        return out
    }

    /// Brackets outside strings, tagged with their nesting depth.
    private static func brackets(_ ns: NSString, in range: NSRange) -> [(NSRange, Token)] {
        var out: [(NSRange, Token)] = []
        var depth = 0
        var inString = false
        var escaped = false
        for i in range.location..<NSMaxRange(range) {
            let c = ns.character(at: i)
            if inString {
                if escaped { escaped = false } else if c == 0x5C { escaped = true } else if c == 0x22 { inString = false }
                continue
            }
            switch c {
            case 0x22: inString = true
            case 0x7B, 0x5B:  // { [
                out.append((NSRange(location: i, length: 1), .bracket(depth)))
                depth += 1
            case 0x7D, 0x5D:  // } ]
                depth = max(depth - 1, 0)
                out.append((NSRange(location: i, length: 1), .bracket(depth)))
            default: break
            }
        }
        return out
    }

    /// Status/request line, `Name: value` headers, then a JSON-highlighted body.
    private static func http(_ ns: NSString) -> [(NSRange, Token)] {
        var out: [(NSRange, Token)] = []
        var location = 0
        var lineIndex = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line).trimmingCharacters(in: .newlines)
            if content.isEmpty {
                let bodyStart = NSMaxRange(line)
                out += json(ns, in: NSRange(location: bodyStart, length: ns.length - bodyStart))
                break
            }
            if lineIndex == 0 {
                out.append((NSRange(location: line.location, length: (content as NSString).length), .statusLine))
            } else if let colon = content.firstIndex(of: ":") {
                let nameLength = (String(content[..<colon]) as NSString).length
                out.append((NSRange(location: line.location, length: nameLength), .headerName))
                let valueStart = line.location + nameLength + 1
                out.append((NSRange(location: valueStart, length: (content as NSString).length - nameLength - 1), .headerValue))
            }
            location = NSMaxRange(line)
            lineIndex += 1
        }
        return out
    }

    static func nsColor(_ hex: String) -> NSColor {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    /// SwiftUI text for read-only views (flow detail).
    static func attributed(_ text: String, kind: SyntaxKind, dark: Bool) -> AttributedString {
        let palette = Theme.current.palette(dark: dark)
        let ns = NSMutableAttributedString(string: text)
        for (range, token) in spans(text, kind: kind) {
            guard let hex = token.hex(in: palette) else { continue }
            ns.addAttribute(.foregroundColor, value: nsColor(hex), range: range)
        }
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(text)
    }
}

/// Editable, syntax-highlighted code view (NSTextView) used by the Map Local and Script editors.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    let kind: SyntaxKind

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.delegate = context.coordinator
        tv.string = text
        context.coordinator.highlight(tv)
        scroll.borderType = .bezelBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
        context.coordinator.highlight(tv)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView

        init(_ parent: CodeTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            highlight(tv)
        }

        func highlight(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let dark = tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let palette = Theme.current.palette(dark: dark)
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                   .foregroundColor: NSColor.textColor], range: all)
            for (range, token) in Syntax.spans(tv.string, kind: parent.kind) {
                guard let hex = token.hex(in: palette) else { continue }
                storage.addAttribute(.foregroundColor, value: Syntax.nsColor(hex), range: range)
            }
            storage.endEditing()
        }
    }
}
