//
//  YAMLPreviewProvider.swift
//  Extension
//

import Cocoa

// MARK: - 职责说明
//
// 负责 .meta 文件（及其他文本格式资产）的预览。
//
// 工作流程：
//   1. 读取文件内容
//   2. 尝试以 UTF-8 解码，判断是文本还是二进制
//   3a. 如果是文本：用 YAMLHighlighter 生成带语法高亮的 NSAttributedString，装进 NSTextView 返回
//   3b. 如果是二进制：返回一个提示视图，告知用户无法预览

struct YAMLPreviewProvider {

    // MARK: - 公开接口

    /// 根据文件内容生成对应的预览视图。
    func makeView(for url: URL) async throws -> NSView {

        // 读取文件
        let data = try Data(contentsOf: url)

        // 尝试以 UTF-8 解码
        guard let text = String(data: data, encoding: .utf8) else {
            return await makeBinaryNoticeView(fileName: url.lastPathComponent)
        }

        // 生成带语法高亮的 NSTextView 预览
        return await makeTextPreviewView(for: text)
    }

    // MARK: - 文本预览（NSTextView）

    /// 创建带语法高亮的 NSScrollView + NSTextView。
    @MainActor
    private func makeTextPreviewView(for text: String) -> NSView {
        let highlighter = YAMLHighlighter()
        let attributed = highlighter.generateAttributedString(
            for: text,
            appearance: NSApp.effectiveAppearance
        )

        // NSScrollView 容器
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // NSTextView
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 12)

        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        textView.textStorage?.setAttributedString(attributed)

        scrollView.documentView = textView

        return scrollView
    }

    // MARK: - 二进制提示视图

    /// 创建"不支持预览"的提示视图，用于 Unity Binary 格式的文件。
    @MainActor
    private func makeBinaryNoticeView(fileName: String) -> NSView {

        // MARK: 图标

        let iconView = NSImageView()
        if let icon = NSImage(systemSymbolName: "document.badge.ellipsis",
                              accessibilityDescription: "Binary file") {
            let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .thin)
            iconView.image = icon.withSymbolConfiguration(config)
        }
        iconView.contentTintColor = .tertiaryLabelColor

        if #available(macOS 26, *) {
            iconView.addSymbolEffect(.drawOn.byLayer, options: .nonRepeating)
        }

        // MARK: 文字标题

        let titleLabel = NSTextField(labelWithString: "无法预览此文件")
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center

        // MARK: 文字说明

        let bodyLabel = NSTextField(wrappingLabelWithString:
            "\(fileName) 使用 Unity Binary 格式存储，不支持文本预览。\n\n" +
            "如需查看内容，请在 Unity Editor 中打开项目，\n" +
            "或在 Project Settings → Editor → Asset Serialization\n" +
            "中将模式改为 Force Text。"
        )
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .tertiaryLabelColor
        bodyLabel.alignment = .center

        // MARK: 布局

        let stack = NSStackView(views: [iconView, titleLabel, bodyLabel])
        stack.orientation = .vertical
        stack.alignment   = .centerX
        stack.spacing     = 12

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])

        return container
    }
}
