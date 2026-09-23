//
//  PackagePreviewProvider.swift
//  Extension
//

import Cocoa

// MARK: - 入口

struct PackagePreviewProvider {

    /// 读取 .unitypackage，返回目录树预览视图。
    func makeView(for url: URL) async throws -> NSView {
        let reader = UnityPackageReader()
        do {
            // read(from:) 内部会解压归档，是耗时操作，放在 async 上下文里执行
            let root = try reader.read(from: url)
            
            // 构建 UI 必须在主线程
            return await MainActor.run {
                PackagePreviewContainerView(root: root, fileName: url.lastPathComponent)
            }
        } catch {
            // 抛错的话 Quick Look 只会显示它自己的通用兜底页，看不到我们的说明，
            // 所以这里改成把错误渲染成视图
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return await MainActor.run {
                PreviewNotice.make(symbolName: "exclamationmark.triangle",
                                   symbolDescription: "Exclamation mark in a triangle",
                                   title: "无法预览此文件", body: "\(url.lastPathComponent) \n\n \(message)")
            }
        }
    }
}

// MARK: - 容器视图

/// 持有目录树视图及其数据源的容器。
///
/// 为什么需要单独的容器视图？
///   NSOutlineView 对 dataSource 和 delegate 持有的是弱引用（weak）。
///   弱引用不会阻止对象被释放——如果 dataSource 没有其他强引用持有它，
///   它会在创建后立刻被 ARC 释放，outlineView 的 dataSource 变成 nil，
///   导致列表显示为空。
///
///   把 dataSource 作为容器视图的属性存储，容器视图本身被 Quick Look 强引用，
///   dataSource 的生命周期就和视图绑定在一起了。
///
/// ARC（Automatic Reference Counting）：
///   Swift 用 ARC 管理内存，每个对象有一个引用计数，
///   计数降为 0 时对象被释放。strong 引用让计数 +1，weak 引用不增加计数。
private final class PackagePreviewContainerView: NSView {

    // strong 引用，保证 dataSource 不被 ARC 提前释放
    private let dataSource: PackageOutlineDataSource

    init(root: PackageNode, fileName: String) {
        // 先初始化存储属性，再调用 super.init
        // 这是 Swift 的"两阶段初始化"规则：
        //   阶段 1：所有存储属性必须在 super.init 之前赋初值
        //   阶段 2：super.init 之后才能调用 self 的方法和访问 self
        self.dataSource = PackageOutlineDataSource(root: root)

        // NSView 的指定初始化器需要一个初始 frame
        // 用 .zero 即可，Auto Layout 会接管最终尺寸
        super.init(frame: .zero)

        setupUI(fileName: fileName)
    }

    // 当视图从 xib/storyboard 加载时会调用这个初始化器。
    // 我们不支持这种用法，用 fatalError 明确表达这一点。
    // fatalError 会立即终止程序并打印信息，比静默失败更容易发现问题。
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PackagePreviewContainerView 不支持从 xib 加载")
    }

    // MARK: - UI 组装

    private func setupUI(fileName: String) {

        // MARK: 标题栏

        // 显示包文件名和资产数量
        let titleBar = makeTitleBar(fileName: fileName)

        // MARK: 目录树

        let outlineView = makeOutlineView()
        let scrollView  = makeScrollView(containing: outlineView)

        // MARK: 垂直布局

        let stack = NSStackView(views: [titleBar, scrollView])
        stack.orientation = .vertical
        stack.spacing     = 0
        // NSStackView 默认在边缘有内边距，这里去掉，让内容铺满
        stack.edgeInsets  = .init(top: 0, left: 0, bottom: 0, right: 0)

        // NSStackView 对子视图的 hugging / compression 优先级有默认值。
        // 我们希望 scrollView 尽量撑满剩余空间，把它的 hugging 优先级设低，
        // 让它在有多余空间时主动扩展，而不是收缩到最小。
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // 全部加载完成后展开第一层，让用户立即看到内容
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: false)
    }

    // MARK: - 子视图工厂

    private func makeTitleBar(fileName: String) -> NSView {
        // 图标
        let iconView = NSImageView()
        if let icon = NSImage(systemSymbolName: "shippingbox",
                              accessibilityDescription: "Unity Package") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            iconView.image = icon.withSymbolConfiguration(config)
        }
        iconView.contentTintColor = .secondaryLabelColor

        // 文件名标签
        let label = NSTextField(labelWithString: fileName)
        label.font        = .systemFont(ofSize: 12, weight: .medium)
        label.textColor   = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle  // 超长文件名从中间截断，保留后缀

        // 标题栏横向布局
        let bar = NSStackView(views: [iconView, label])
        bar.orientation = .horizontal
        bar.spacing     = 6
        bar.edgeInsets  = .init(top: 8, left: 12, bottom: 8, right: 12)
        bar.alignment   = .centerY

        // 标题栏背景（使用系统控件背景色，深浅模式自动适配）
        bar.wantsLayer       = true
        bar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // 底部分隔线
        let separator       = NSBox()
        separator.boxType   = .separator

        let container = NSStackView(views: [bar, separator])
        container.orientation = .vertical
        container.spacing     = 0
        container.edgeInsets  = .init()  // NSEdgeInsets 没有 .zero，无参 init() 所有值默认为 0

        return container
    }

    private func makeOutlineView() -> NSOutlineView {
        let outlineView = NSOutlineView()

        // NSOutlineView 至少需要一个列
        let column = NSTableColumn(identifier: .init("name"))
        column.title = "文件"
        // minWidth 防止列被拖得太窄
        column.minWidth = 200
        outlineView.addTableColumn(column)

        // outlineTableColumn 指定哪一列显示展开/折叠的三角箭头
        outlineView.outlineTableColumn = column

        // 隐藏列头（Quick Look 里不需要列标题）
        outlineView.headerView = nil

        // 行高
        outlineView.rowHeight = 22

        // 连接数据源和委托（都由同一个对象实现）
        outlineView.dataSource = dataSource
        outlineView.delegate   = dataSource

        return outlineView
    }

    private func makeScrollView(containing documentView: NSView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView        = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers  = true  // 没有溢出时自动隐藏滚动条
        scrollView.borderType          = .noBorder

        return scrollView
    }
}

// MARK: - 数据源 & 委托

/// NSOutlineView 的数据源和委托，负责提供目录树数据和渲染每一行。
///
/// 为什么继承 NSObject？
///   NSOutlineViewDataSource 和 NSOutlineViewDelegate 是 Objective-C 协议。
///   实现这些协议的类必须继承自 NSObject，
///   因为 Objective-C 的消息派发机制依赖 NSObject 的运行时基础设施。
///   纯 Swift 的 class 不继承 NSObject，无法被 Objective-C 运行时识别。
private final class PackageOutlineDataSource: NSObject,
                                               NSOutlineViewDataSource,
                                               NSOutlineViewDelegate {

    private let root: PackageNode

    init(root: PackageNode) {
        self.root = root
        // NSObject 的指定初始化器没有参数，必须显式调用
        super.init()
    }

    // MARK: NSOutlineViewDataSource

    /// 返回某个节点的子节点数量。
    /// item == nil 表示"根级别"，对应我们虚拟根节点的直接子节点。
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? PackageNode else { return root.children.count }
        return node.children.count
    }

    /// 返回某个节点的第 index 个子节点。
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? PackageNode else { return root.children[index] }
        return node.children[index]
    }

    /// 返回某个节点是否可展开（即是否为文件夹）。
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return (item as? PackageNode)?.isDirectory ?? false
    }

    // MARK: NSOutlineViewDelegate

    /// 返回某一行的视图。
    /// 这里我们自己构建 NSTableCellView，而不是用 makeView(withIdentifier:owner:) 复用，
    /// 因为 Quick Look 扩展的生命周期很短，复用池的收益有限。
    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {

        guard let node = item as? PackageNode else { return nil }

        // MARK: 图标

        let iconView = NSImageView()
        let symbolName = node.isDirectory ? "folder" : sfSymbol(for: node.name)
        if let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            iconView.image = icon.withSymbolConfiguration(config)
        }
        // 文件夹用系统黄色，文件用次要标签色
        iconView.contentTintColor = node.isDirectory ? .init(named: "FolderColor") ?? .systemYellow
                                                     : .secondaryLabelColor

        // MARK: 文件名

        let textField = NSTextField(labelWithString: node.name)
        textField.font          = .systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail

        // MARK: 横向排列图标和文字

        let cellStack = NSStackView(views: [iconView, textField])
        cellStack.orientation = .horizontal
        cellStack.spacing     = 5
        cellStack.alignment   = .centerY
        // edgeInsets 给行内容加左右内边距
        cellStack.edgeInsets  = .init(top: 0, left: 2, bottom: 0, right: 4)

        // NSTableCellView 是 NSOutlineView 行视图的标准容器
        let cellView = NSTableCellView()
        cellView.textField = textField
        cellView.imageView = iconView

        cellStack.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(cellStack)
        NSLayoutConstraint.activate([
            cellStack.topAnchor.constraint(equalTo: cellView.topAnchor),
            cellStack.bottomAnchor.constraint(equalTo: cellView.bottomAnchor),
            cellStack.leadingAnchor.constraint(equalTo: cellView.leadingAnchor),
            cellStack.trailingAnchor.constraint(equalTo: cellView.trailingAnchor),
        ])

        return cellView
    }

    // MARK: - 图标辅助

    /// 根据文件扩展名返回对应的 SF Symbol 名称。
    private func sfSymbol(for fileName: String) -> String {
        // (fileName as NSString).pathExtension 是 Foundation 提供的扩展名提取方法，
        // 等价于 URL(fileURLWithPath: fileName).pathExtension，但不需要构造 URL
        let ext = (fileName as NSString).pathExtension.lowercased()

        switch ext {
        case "cs":                          return "text.document"           // C# 脚本
        case "shader", "hlsl", "glsl":      return "sparkles"           // Shader
        case "mat":                         return "circle.hexagongrid" // 材质
        case "prefab":                      return "cube"               // 预制体
        case "unity":                       return "square.3.layers.3d" // 场景
        case "asset":                       return "archivebox"         // 通用资产
        case "png", "jpg", "jpeg",
             "tga", "bmp", "exr", "hdr":    return "photo"              // 贴图
        case "mp3", "wav", "ogg", "aiff":   return "waveform"           // 音频
        case "fbx", "obj", "dae":           return "rotate.3d"          // 模型
        case "anim":                        return "figure.walk"        // 动画
        case "controller":                  return "point.3.connected.trianglepath.dotted" // 动画控制器
        case "ttf", "otf":                  return "textformat"         // 字体
        case "json", "xml", "yaml",
             "yml", "txt", "md", "meta":    return "text.page"      // 文本
        case "dll":                         return "puzzlepiece.extension"        // 插件
        default:                            return "questionmark.text.page"                // 未知类型
        }
    }
}
