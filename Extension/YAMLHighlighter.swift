//
//  YAMLHighlighter.swift
//  Extension
//

import AppKit

// MARK: - 职责说明
//
// 把一段 YAML/Unity 文本渲染为带语法高亮的 NSAttributedString，
// 供 NSTextView 直接显示。
//
// Quick Look 扩展运行在严格沙盒中，WKWebView 无法启动子进程，
// 因此用原生 AppKit 文本系统代替 Web 渲染引擎。

struct YAMLHighlighter {

    // MARK: - 颜色方案

    private struct Colors {
        let background: NSColor
        let text: NSColor
        let lineNumberText: NSColor
        let docMark: NSColor
        let directive: NSColor
        let key: NSColor
        let string: NSColor
        let number: NSColor
        let bool: NSColor
        let tag: NSColor
        let anchor: NSColor
        let seq: NSColor
        let url: NSColor
    }

    private static let light = Colors(
        background:            .white,
        text:                  NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        lineNumberText:        NSColor(white: 0.73, alpha: 1),
        docMark:               NSColor(red: 0.69, green: 0.00, blue: 0.86, alpha: 1),
        directive:             NSColor(red: 0.69, green: 0.00, blue: 0.86, alpha: 1),
        key:                   NSColor(red: 0.02, green: 0.32, blue: 0.65, alpha: 1),
        string:                NSColor(red: 0.64, green: 0.08, blue: 0.08, alpha: 1),
        number:                NSColor(red: 0.04, green: 0.53, blue: 0.35, alpha: 1),
        bool:                  NSColor(red: 0.00, green: 0.00, blue: 1.00, alpha: 1),
        tag:                   NSColor(red: 0.47, green: 0.37, blue: 0.15, alpha: 1),
        anchor:                NSColor(red: 0.15, green: 0.50, blue: 0.60, alpha: 1),
        seq:                   NSColor(red: 0.69, green: 0.00, blue: 0.86, alpha: 1),
        url:                   NSColor(red: 0.10, green: 0.48, blue: 0.55, alpha: 1)
    )

    private static let dark = Colors(
        background:            NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1),
        text:                  NSColor(red: 0.83, green: 0.83, blue: 0.83, alpha: 1),
        lineNumberText:        NSColor(white: 0.31, alpha: 1),
        docMark:               NSColor(red: 0.77, green: 0.50, blue: 0.75, alpha: 1),
        directive:             NSColor(red: 0.77, green: 0.50, blue: 0.75, alpha: 1),
        key:                   NSColor(red: 0.61, green: 0.86, blue: 1.00, alpha: 1),
        string:                NSColor(red: 0.81, green: 0.57, blue: 0.47, alpha: 1),
        number:                NSColor(red: 0.71, green: 0.81, blue: 0.66, alpha: 1),
        bool:                  NSColor(red: 0.34, green: 0.61, blue: 0.84, alpha: 1),
        tag:                   NSColor(red: 0.86, green: 0.86, blue: 0.77, alpha: 1),
        anchor:                NSColor(red: 0.31, green: 0.81, blue: 0.69, alpha: 1),
        seq:                   NSColor(red: 0.77, green: 0.50, blue: 0.75, alpha: 1),
        url:                   NSColor(red: 0.40, green: 0.78, blue: 0.85, alpha: 1)
    )

    // MARK: - 词法正则

    /// URL
    private static let urlPattern = #/^https?:\/\/\S+/#

    /// YAML 1.2 core schema 的标量数字（含 0b/0x、`.5`、指数、正负号）
    private static let numberPattern = #"^[-+]?(0[bB][01]+|0[xX][0-9a-fA-F]+|[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?|\.[0-9]+([eE][-+]?[0-9]+)?)$"#

    // MARK: - 公开接口
    
    static func background(for appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (isDark ? dark : light).background
    }

    /// 生成带语法高亮的 NSAttributedString。
    func generateAttributedString(for text: String, appearance: NSAppearance) -> NSAttributedString {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let c: Colors = isDark ? Self.dark : Self.light

        let lineSpacing = NSMutableParagraphStyle()
        lineSpacing.lineHeightMultiple = 1.1

        let base: [NSAttributedString.Key: Any] = [
            .font:            NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: c.text,
            .paragraphStyle:  lineSpacing,
        ]

        let result = NSMutableAttributedString(string: "", attributes: base)
        let lines = text.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: base)) }

            // 行号
            let numStyle = NSMutableParagraphStyle()
            numStyle.lineHeightMultiple = 1.1
            let lineNum = NSAttributedString(string: String(format: "%4d  ", index + 1), attributes: [
                .font:            NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: c.lineNumberText,
                .paragraphStyle:  numStyle,
            ])
            result.append(lineNum)

            // 行内容
            result.append(highlightLine(line, colors: c, base: base))
        }
        return result
    }

    // MARK: - 行级高亮（移植自 yaml-highlight.js）

    private func highlightLine(_ line: String, colors c: Colors, base: [NSAttributedString.Key: Any]) -> NSAttributedString {

        // 1. 文档标记 --- 或 ...
        if let m = line.range(of: #"^(---)"#, options: .regularExpression) {
            let mark = String(line[m])
            let rest = String(line[m.upperBound...])
            let result = NSMutableAttributedString(string: mark, attributes: withColor(base, c.docMark, bold: true))
            result.append(highlightAfterDocMarker(rest, colors: c, base: base))
            return result
        }

        // 2. YAML 指令（% 开头）
        if line.hasPrefix("%") {
            return line.attr(base, color: c.directive)
        }

        // 3. 普通键值对
        return highlightKeyValue(line, colors: c, base: base)
    }

    // MARK: - 文档标记后的内容（--- 之后）

    private func highlightAfterDocMarker(_ rest: String, colors c: Colors, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else {
            return NSAttributedString(string: rest, attributes: base)
        }

        let result = NSMutableAttributedString()
        var lastEnd = rest.startIndex

        // Unity 文档 tag !u!21 与锚点 &123456（真实样本里两者总是同时出现在 --- 行上）
        for m in rest.matches(of: #/(!u![0-9]+|&[0-9a-zA-Z_]+)/#) {
            let range = m.range
            if range.lowerBound > lastEnd {
                result.append(NSAttributedString(string: String(rest[lastEnd..<range.lowerBound]), attributes: base))
            }
            let token = String(rest[range])
            let color = token.hasPrefix("&") ? c.anchor : c.tag
            result.append(NSAttributedString(string: token, attributes: withColor(base, color)))
            lastEnd = range.upperBound
        }

        if lastEnd < rest.endIndex {
            result.append(NSAttributedString(string: String(rest[lastEnd...]), attributes: base))
        }

        return result.length > 0 ? result : NSAttributedString(string: rest, attributes: base)
    }

    // MARK: - 键值对

    private func highlightKeyValue(_ line: String, colors c: Colors, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        // 捕获前导缩进
        let indentLen = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let indent = String(line.prefix(indentLen))
        let trimmed = String(line.dropFirst(indentLen))

        let result = NSMutableAttributedString()
        if !indent.isEmpty {
            result.append(NSAttributedString(string: indent, attributes: base))
        }

        // 列表项
        if trimmed.hasPrefix("- ") || trimmed == "-" {
            result.append(NSAttributedString(string: "- ", attributes: withColor(base, c.seq, bold: true)))
            let rest = String(trimmed.dropFirst(2))
            result.append(highlightKeyValue(rest, colors: c, base: base))
            return result
        }

        // 键: 值
        if let split = splitKeyValue(trimmed) {
            result.append(split.key.attr(base, color: c.key))
            result.append(NSAttributedString(string: split.separator, attributes: base))
            result.append(highlightValue(split.value, colors: c, base: base))
        } else {
            result.append(highlightValue(trimmed, colors: c, base: base))
        }

        return result
    }

    /// 找第一个「不在引号内」的冒号作为键值分隔符。
    /// - 跳过 `"a:b"` 这类引号内的冒号
    /// - `://` 不当作分隔符（避免把裸 URL 的 scheme 当成键）
    /// - 返回 nil 表示这一行不是 `key: value`
    private func splitKeyValue(_ line: String) -> (key: String, separator: String, value: String)? {
        var inSingle = false
        var inDouble = false
        var escaped = false
        var colon: String.Index?

        var i = line.startIndex
        loop: while i < line.endIndex {
            let ch = line[i]
            if escaped {
                escaped = false
            } else if ch == "\\" && inDouble {
                escaped = true
            } else if ch == "'" && !inDouble {
                inSingle.toggle()
            } else if ch == "\"" && !inSingle {
                inDouble.toggle()
            } else if ch == ":" && !inSingle && !inDouble {
                colon = i
                break loop
            }
            i = line.index(after: i)
        }

        guard let colon else { return nil }
        let afterColon = line.index(after: colon)
        if afterColon < line.endIndex, line[afterColon] == "/" { return nil }  // ://

        let key = String(line[line.startIndex..<colon])
        guard !key.isEmpty else { return nil }

        var valueStart = afterColon
        while valueStart < line.endIndex, line[valueStart] == " " || line[valueStart] == "\t" {
            valueStart = line.index(after: valueStart)
        }
        return (key, String(line[colon..<valueStart]), String(line[valueStart...]))
    }

    // MARK: - 值高亮

    private func highlightValue(_ val: String, colors c: Colors, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard !val.isEmpty else { return NSAttributedString(string: "", attributes: base) }

        let result = NSMutableAttributedString()

        let lower = val.lowercased()

        if let url = val.firstMatch(of: Self.urlPattern) {
            // 值以 URL 开头：URL 部分单独上色，其余原样
            result.append(String(url.output).attr(base, color: c.url))
            result.append(NSAttributedString(string: String(val[url.range.upperBound...]), attributes: base))
        } else if ["true", "false", "yes", "no", "on", "off"].contains(lower) {
            result.append(val.attr(base, color: c.bool))
        } else if val.range(of: Self.numberPattern, options: .regularExpression) != nil {
            result.append(val.attr(base, color: c.number))
        } else if val.hasPrefix("\"") || val.hasPrefix("'") {
            result.append(val.attr(base, color: c.string))
        } else if val.hasPrefix("{") || val.hasPrefix("[") {
            result.append(highlightFlowMapping(val, colors: c, base: base))
        } else {
            result.append(NSAttributedString(string: val, attributes: base))
        }

        return result
    }

    // MARK: - 流式集合（映射 {…} / 序列 […]）

    private func highlightFlowMapping(_ text: String, colors c: Colors, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var lastEnd = text.startIndex

        // 高亮键名
        for m in text.matches(of: #/([\w$.\-]+?)(\s*:)/#) {
            let range = m.range
            if range.lowerBound > lastEnd {
                let middle = String(text[lastEnd..<range.lowerBound])
                result.append(highlightFlowNumbers(middle, colors: c, base: base))
            }
            result.append(NSAttributedString(string: String(m.1), attributes: withColor(base, c.key)))
            result.append(NSAttributedString(string: String(m.2), attributes: base))
            lastEnd = range.upperBound
        }

        if lastEnd < text.endIndex {
            let rest = String(text[lastEnd...])
            result.append(highlightFlowNumbers(rest, colors: c, base: base))
        }

        return result.length > 0 ? result : NSAttributedString(string: text, attributes: base)
    }

    private func highlightFlowNumbers(_ text: String, colors c: Colors, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var lastEnd = text.startIndex

        for m in text.matches(of: #/\b(-?(?:0x[0-9a-fA-F]+|[0-9]+(?:\.[0-9]+)?|\.[0-9]+))\b/#) {
            let range = m.range
            if range.lowerBound > lastEnd {
                result.append(NSAttributedString(string: String(text[lastEnd..<range.lowerBound]), attributes: base))
            }
            result.append(NSAttributedString(string: String(text[range]), attributes: withColor(base, c.number)))
            lastEnd = range.upperBound
        }

        if lastEnd < text.endIndex {
            result.append(NSAttributedString(string: String(text[lastEnd...]), attributes: base))
        }

        return result.length > 0 ? result : NSAttributedString(string: text, attributes: base)
    }

    // MARK: - 辅助

    private func withColor(_ base: [NSAttributedString.Key: Any], _ color: NSColor, bold: Bool = false) -> [NSAttributedString.Key: Any] {
        var attrs = base
        attrs[.foregroundColor] = color
        if bold {
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        }
        return attrs
    }
}

// MARK: - NSAttributedString 拼接运算符

private func + (lhs: NSMutableAttributedString, rhs: NSAttributedString) -> NSMutableAttributedString {
    lhs.append(rhs)
    return lhs
}

private func += (lhs: inout NSMutableAttributedString, rhs: NSAttributedString) {
    lhs.append(rhs)
}

// MARK: - String → NSAttributedString 便捷方法

private extension String {
    func attr(_ base: [NSAttributedString.Key: Any], color: NSColor) -> NSAttributedString {
        var attrs = base
        attrs[.foregroundColor] = color
        return NSAttributedString(string: self, attributes: attrs)
    }
}
