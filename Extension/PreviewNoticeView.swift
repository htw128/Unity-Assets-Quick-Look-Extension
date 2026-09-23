//
//  PreviewNoticeView.swift
//  UnityAssetsQuickLook
//
//  Created by Oliver Wong on 2026/9/23.
//

import Cocoa

/// 通用的「无法预览」提示视图：图标 + 标题 + 说明文字，整体居中。
/// YAMLPreviewProvider 与 PackagePreviewProvider 共用，保证提示样式一致。
enum PreviewNotice {

    @MainActor
    static func make(symbolName: String, symbolDescription: String, title: String, body: String) -> NSView {
        // MARK: 图标

        let iconView = NSImageView()
        if let icon = NSImage(systemSymbolName: symbolName,
                              accessibilityDescription: symbolDescription) {
            let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .thin)
            iconView.image = icon.withSymbolConfiguration(config)
        }
        iconView.contentTintColor = .tertiaryLabelColor

        if #available(macOS 26, *) {
            iconView.addSymbolEffect(.drawOn.byLayer, options: .nonRepeating)
        }

        // MARK: 文字标题

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center

        // MARK: 文字说明

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
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
