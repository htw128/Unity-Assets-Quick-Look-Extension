//
//  PreviewViewController.swift
//  Exntension
//
//  Created by Oliver Wong on 2026/4/23.
//

import Cocoa
import Quartz

// MARK: - 什么是 QLPreviewingController？
//
// Quick Look 扩展必须实现这个协议。
// 当用户在 Finder 中按空格键预览文件时，系统会：
//   1. 找到能处理该文件 UTType 的扩展（通过 Info.plist 声明）
//   2. 实例化 NSExtensionPrincipalClass 指定的类（即本类）
//   3. 调用 preparePreviewOfFile(at:) 方法
//   4. 等待方法返回后，把 self.view 显示给用户

class PreviewViewController: NSViewController, QLPreviewingController {

    // MARK: - 视图加载

    // nibName 告诉父类 NSViewController 去哪里找对应的 .xib 界面文件。
    // Xcode 模板已经帮我们生成了 PreviewViewController.xib，这里直接引用它。
    override var nibName: NSNib.Name? {
        return NSNib.Name("PreviewViewController")
    }

    override func loadView() {
        // 调用父类方法，它会去加载上面 nibName 指定的 .xib 文件，
        // 并把 xib 的根视图赋值给 self.view。
        super.loadView()
    }

    // MARK: - QLPreviewingController 协议实现

    /// Quick Look 框架调用此方法，让我们准备文件预览。
    ///
    /// - Parameter url: 要预览的文件的本地路径（已被系统复制到沙盒临时目录）
    ///
    /// 注意事项：
    /// - `async throws`：这是 Swift 并发语法。
    ///   `async` 表示方法可以"挂起"（暂停执行等待某件事），不会阻塞线程。
    ///   `throws` 表示方法可能抛出错误，调用方需要用 `try` 处理。
    /// - Quick Look 会显示加载动画，直到这个方法返回（return 或 throw）。
    /// - 不要在这里直接操作 UI —— UI 操作必须在主线程，
    ///   而此方法可能在后台线程被调用。用 MainActor.run 切换回主线程。
    func preparePreviewOfFile(at url: URL) async throws {
        let ext = url.pathExtension.lowercased()
        
        switch ext{
        case "unitypackage":
            // try await showPackagePreview(for: url) TODO 沙箱里现在没法直接调用命令行工具，Apple Archive也不是很好用。这个功能先挂起
        default:
            try await showYAMLPreview(for: url)
        }
        // 读取文件扩展名并转为小写，以便不区分大小写地匹配
        
    }

    // MARK: - 私有路由方法

    /// 创建并展示 YAML 预览视图（用于 .meta 等文本格式文件）。
    private func showYAMLPreview(for url: URL) async throws {
        let provider = YAMLPreviewProvider()

        // makeView(for:) 内部会读取文件，是耗时 I/O 操作。
        // 在 async 上下文中调用它，Swift 运行时会把它调度到合适的线程，
        // 不会卡住主线程（也就不会卡住 UI）。
        let childView = try await provider.makeView(for: url)

        // await MainActor.run { } 把花括号内的代码"切换"到主线程执行。
        // 所有 NSView / AppKit 的创建和修改都必须在主线程进行。
        await MainActor.run {
            embed(childView)
        }
    }

    /// 创建并展示 .unitypackage 目录树预览视图。
    private func showPackagePreview(for url: URL) async throws {
        let provider = PackagePreviewProvider()
        let childView = try await provider.makeView(for: url)

        await MainActor.run {
            embed(childView)
        }
    }

    // MARK: - 视图布局辅助

    /// 将子视图嵌入 self.view，并用 Auto Layout 约束让它铺满整个父视图。
    ///
    /// Auto Layout 简介：
    /// macOS/iOS 使用"约束"来描述视图的位置和大小，而不是直接写死坐标。
    /// 这样当窗口尺寸变化时，视图可以自动适应。
    ///
    /// - Parameter child: 要嵌入的子视图
    private func embed(_ child: NSView) {
        // 必须先设为 false，否则系统会自动根据 frame 生成约束，
        // 与我们手动添加的约束产生冲突。
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)

        // 激活四条约束，让子视图的四条边分别与父视图对齐
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),   // leading = 左（支持 RTL 语言）
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor), // trailing = 右
        ])
    }
}
