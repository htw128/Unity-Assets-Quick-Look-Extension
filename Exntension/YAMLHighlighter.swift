//
//  YAMLHighlighter.swift
//  Exntension
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
        let lineNumberBackground: NSColor
        let comment: NSColor
        let docMark: NSColor
        let directive: NSColor
        let key: NSColor
        let string: NSColor
        let number: NSColor
        let bool: NSColor
        let tag: NSColor
        let anchor: NSColor
        let seq: NSColor
    }

    private static let light = Colors(
        background:            .white,
        text:                  NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        lineNumberText:        NSColor(white: 0.73, alpha: 1),
        lineNumberBackground:  NSColor(white: 0.97, alpha: 1),
        comment:               NSColor(red: 0.42, green: 0.60, blue: 0.33, alpha: 1),
        docMark:               NSColor(red: 0.69, green: 0.00, blue: 0.86, alpha: 1),
        directive:             NSColor(red: 0.69, green: 0.00, blue: 0.86, alpha: 1),
        key:                   NSColor(red: 0.02, green: 0.32, blue: 0.65, alpha: 1),
        string:                NSColor(red: 0.64, green: 0.08, blue: 0.08, alpha: 1),
        number:                NSColor(red: 0.04, green: 0.53, blue: 0.35, alpha: 1),
        bool:                  NSColor(red: 0.00, green: 0.00, blue: 1.00, alpha: 1),
        tag:                   NSColor(red: 0.47, green: 0.37, blue: 0.15, alpha: 1),
        anchor:                NSColor(red: 0.15, green: 0.50, blue: 0.60, alpha: 1),
        seq:                   NSColor(red: 0.69, green: 0.00, blue: 0.86, alpha: 1)
    )

    private static let dark = Colors(
        background:            NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1),
        text:                  NSColor(red: 0.83, green: 0.83, blue: 0.83, alpha: 1),
        lineNumberText:        NSColor(white: 0.31, alpha: 1),
        lineNumberBackground:  NSColor(white: 0.15, alpha: 1),
        comment:               NSColor(red: 0.42, green: 0.60, blue: 0.33, alpha: 1),
        docMark:               NSColor(red: 0.77, green: 0.50, blue: 0.75, alpha: 1),
        directive:             NSColor(red: 0.77, green: 0.50, blue: 0.75, alpha: 1),
        key:                   NSColor(red: 0.61, green: 0.86, blue: 1.00, alpha: 1),
        string:                NSColor(red: 0.81, green: 0.57, blue: 0.47, alpha: 1),
        number:                NSColor(red: 0.71, green: 0.81, blue: 0.66, alpha: 1),
        bool:                  NSColor(red: 0.34, green: 0.61, blue: 0.84, alpha: 1),
        tag:                   NSColor(red: 0.86, green: 0.86, blue: 0.77, alpha: 1),
        anchor:                NSColor(red: 0.31, green: 0.81, blue: 0.69, alpha: 1),
        seq:                   NSColor(red: 0.77, green: 0.50, blue: 0.75, alpha: 1)
    )

    // MARK: - 公开接口

    /// 生成带语法高亮的 NSAttributedString。
    func generateAttributedString(for text: String, appearance: NSAppearance) -> NSAttributedString {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let c: Colors = isDark ? Self.dark : Self.light

        let lineSpacing = NSMutableParagraphStyle()
        lineSpacing.lineHeightMultiple = 1.7

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
            numStyle.lineHeightMultiple = 1.7
            let lineNum = NSAttributedString(string: String(format: "%4d  ", index + 1), attributes: [
                .font:            NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: c.lineNumberText,
                .backgroundColor: c.lineNumberBackground,
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
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // 1. 注释行
        if trimmed.hasPrefix("#") {
            return line.attr(base, color: c.comment)
        }

        // 2. 文档标记 --- 或 ...
        if let m = line.range(of: #"^(---|\.\.\.)"#, options: .regularExpression) {
            let mark = String(line[m])
            let rest = String(line[m.upperBound...])
            let result = NSMutableAttributedString(string: mark, attributes: withColor(base, c.docMark, bold: true))
            result.append(highlightAfterDocMarker(rest, colors: c, base: base))
            return result
        }

        // 3. YAML 指令（% 开头）
        if line.hasPrefix("%") {
            return line.attr(base, color: c.directive)
        }

        // 4. 普通键值对
        return highlightKeyValue(line, colors: c, base: base)
    }

    // MARK: - 文档标记后的内容（--- 之后）

    private func highlightAfterDocMarker(_ rest: String, colors c: Colors, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else {
            return NSAttributedString(string: rest, attributes: base)
        }

        let result = NSMutableAttributedString()
        var lastEnd = rest.startIndex

        // Unity 类型标签 !u!21
        for m in rest.matches(of: #/(!u![0-9]+)/#) {
            let range = m.range
            if range.lowerBound > lastEnd {
                result.append(NSAttributedString(string: String(rest[lastEnd..<range.lowerBound]), attributes: base))
            }
            result.append(NSAttributedString(string: String(rest[range]), attributes: withColor(base, c.tag)))
            lastEnd = range.upperBound
        }

        // 锚点 &id 和别名 *id
        if result.length == 0 {
            for m in rest.matches(of: #/([&*][0-9a-zA-Z_]+)/#) {
                let range = m.range
                if range.lowerBound > lastEnd {
                    result.append(NSAttributedString(string: String(rest[lastEnd..<range.lowerBound]), attributes: base))
                }
                result.append(NSAttributedString(string: String(rest[range]), attributes: withColor(base, c.anchor)))
                lastEnd = range.upperBound
            }
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
        if let match = trimmed.firstMatch(of: #/^([^:\n]+?):(\s*)(.*)$/#) {
            let key = String(match.1)
            let sep = ":" + String(match.2)
            let val = String(match.3)

            result.append(key.attr(base, color: c.key))
            result.append(NSAttributedString(string: sep, attributes: base))
            result.append(highlightValue(val, colors: c, base: base))
        } else {
            result.append(highlightValue(trimmed, colors: c, base: base))
        }

        return result
    }

    // MARK: - 值高亮

    private func highlightValue(_ raw: String, colors c: Colors, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard !raw.isEmpty else { return NSAttributedString(string: "", attributes: base) }

        let split = splitTrailingComment(raw)
        let val = split.val
        let comment = split.comment

        let result = NSMutableAttributedString()

        if let val, !val.isEmpty {
            let lower = val.lowercased()

            if ["true", "false", "null", "~", "yes", "no", "on", "off"].contains(lower) {
                result.append(val.attr(base, color: c.bool))
            } else if val.range(of: #"^-?(0x[0-9a-fA-F]+|[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?)$"#, options: .regularExpression) != nil {
                result.append(val.attr(base, color: c.number))
            } else if val.hasPrefix("\"") || val.hasPrefix("'") {
                result.append(val.attr(base, color: c.string))
            } else if val.hasPrefix("{") {
                result.append(highlightFlowMapping(val, colors: c, base: base))
            } else if val.hasPrefix("&") || val.hasPrefix("*") {
                result.append(val.attr(base, color: c.anchor))
            } else {
                result.append(NSAttributedString(string: val, attributes: base))
            }
        }

        if let comment, !comment.isEmpty {
            if result.length > 0 {
                result.append(NSAttributedString(string: " ", attributes: base))
            }
            result.append(comment.attr(base, color: c.comment))
        }

        return result
    }

    // MARK: - 流式映射 {fileID: 123}

    private func highlightFlowMapping(_ text: String, colors c: Colors, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var lastEnd = text.startIndex

        // 高亮键名
        for m in text.matches(of: #/([a-zA-Z_][a-zA-Z0-9_]*)(\s*:)/#) {
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

        for m in text.matches(of: #/\b(-?(?:0x[0-9a-fA-F]+|[0-9]+(?:\.[0-9]+)?))\b/#) {
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

    // MARK: - 行尾注释拆分

    private func splitTrailingComment(_ value: String) -> (val: String?, comment: String?) {
        if value.hasPrefix("#") { return (nil, value) }

        var inSingle = false
        var inDouble = false
        let chars = Array(value)

        for i in 0..<(chars.count - 1) {
            if chars[i] == "'" && !inDouble { inSingle.toggle(); continue }
            if chars[i] == "\"" && !inSingle { inDouble.toggle(); continue }

            if !inSingle && !inDouble && chars[i] == " " && chars[i + 1] == "#" {
                return (String(value.prefix(i)).trimmingCharacters(in: CharacterSet(charactersIn: " ")),
                        String(value.dropFirst(i + 1)))
            }
        }

        return (value, nil)
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
