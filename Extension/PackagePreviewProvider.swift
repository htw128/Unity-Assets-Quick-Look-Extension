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
        // 不用 NSStackView 包一层：竖排 stack 的交叉轴 alignment 默认 .centerX，
        // 不会把子视图拉满整行宽 → 标题栏背景只能覆盖内容那一小块。
        // 显式约束语义无歧义：标题栏横跨整行、按内容定高；滚动视图吃掉剩下的空间。
        // （因此也不再需要那两个 hugging 优先级调整：bottom 约束本身就是 required。）
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleBar)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
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
            iconView.image = icon.withSymbolConfiguration(
                .init(pointSize: 16, weight: .regular)
            )
        }
        iconView.contentTintColor = .secondaryLabelColor

        // 文件名标签
        let label = NSTextField(labelWithString: fileName)
        label.font        = .systemFont(ofSize: 12, weight: .medium)
//        label.textColor   = .textColor
        label.lineBreakMode = .byTruncatingMiddle  // 超长文件名从中间截断，保留后缀
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) // 窄窗口时允许压缩，否则会和下面的 trailing 约束打架（约束冲突会在控制台刷日志）

        // 内容行
        let content = NSStackView(views: [iconView, label])
        content.orientation = .horizontal
        content.spacing     = 6
        content.alignment   = .centerY
        
        // 背景
        // 背景用普通 NSView 而不是 NSStackView：
        //   NSStackView 会 hug 内容，背景只覆盖内容那一小块、不铺满整行；
        //   而且给 stack 设 layer 背景色还踩上面说的「CGColor 一次性解析」坑。
        let bar = AdaptiveBackgroundView(frame: .zero)
        bar.fillColor  = .controlBackgroundColor
        bar.wantsLayer = true
        
        // 底部分割线
        let separator = NSBox()
        separator.boxType = .separator
        
        content.translatesAutoresizingMaskIntoConstraints   = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(content)
        bar.addSubview(separator)
        
        NSLayoutConstraint.activate([
            // 包名居中
            content.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            
            // 两侧留白：用 ≥ / ≤ 而不是 =，超长文件名才会被挤到截断，而不是撑破布局
            content.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -8),

            // 分隔线横跨整行、贴底
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])

        return bar
    }

    private func makeOutlineView() -> NSOutlineView {
        let outlineView = NSOutlineView()

        // NSOutlineView 至少需要一个列
        let column = NSTableColumn(identifier: .init("name"))
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

// MARK: - 自适应背景视图
/// 背景色会随深浅色模式自动更新的纯色视图。
///
/// 为什么不能写成 `layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor`？
///   1. `controlBackgroundColor` 是*动态颜色*，只有在某个 NSAppearance 下解析才有确定的 RGBA；
///      `CGColor` 则是*已经解析过的固定值*。
///   2. `.cgColor` 解析时用的是「当前绘图外观」（NSAppearance.current）。
///      我们在 makeView 里造视图时，视图还没进窗口，拿到的是扩展进程的默认外观（浅色）
///      → 图层被永久钉在白色。深色模式下就成了「白底 + 浅色文字 = 文字完全看不见」。
///   3. 正规解法是 `wantsUpdateLayer = true` + 在 `updateLayer()` 里设色：
///      视图的 effectiveAppearance 一变（切深浅色、窗口换外观），AppKit 就会重新调
///      updateLayer()，颜色随之重新解析。（wantsUpdateLayer 为 true 时不再走 draw(_:)）
private final class AdaptiveBackgroundView: NSView {
    
    var fillColor: NSColor = .controlBackgroundColor {
        didSet { needsDisplay = true }
    }
    
    override var wantsUpdateLayer: Bool { true }
    
    override func updateLayer() {
        layer?.backgroundColor = fillColor.cgColor
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
    /// 走 NSTableView 的复用机制：滚出可视区的行会被回收，再滚回来时只改内容，不重建视图。
    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {

        guard let node = item as? PackageNode else { return nil }
        
        // 先从复用池取，取不到才新建。
        // 返回的 cellView 自带 identifier，NSTableView 才能在它滚出可视区后自动回收。
        let cellView = (outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: nil)
                        as? NSTableCellView) ?? makeCellView()

        // 复用/新建都要走配置：把这一行的内容和状态一次性刷成当前节点的
        cellView.imageView?.image = symbol(named: node.isDirectory ? "folder" : sfSymbol(for: node.name), pointSize: 13)
        // 选中行时 AppKit 会把 NSTableCellView 的 imageView / textField 自动重着色为白色
        // （实测），所以 强调色图标 + 强调色选中背景 不会糊掉 不用手动处理选中状态 `selectionHighlightStyle`
        cellView.imageView?.contentTintColor = node.isDirectory ? .systemBlue : .secondaryLabelColor
        cellView.textField?.stringValue = node.name
        // 树是从完整路径重建的，行里只有最后一段；tooltip 补上 Unity 项目内的完整路径
        cellView.toolTip = node.fullPath ?? node.name

        return cellView
    }

    // MARK: - 图标辅助

    /// 根据文件扩展名返回对应的 SF Symbol 名称。
    private func sfSymbol(for fileName: String) -> String {
        // (fileName as NSString).pathExtension 是 Foundation 提供的扩展名提取方法，
        // 等价于 URL(fileURLWithPath: fileName).pathExtension，但不需要构造 URL
        let ext = (fileName as NSString).pathExtension.lowercased()

        switch ext {
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
        case "json", "xml", "yaml", "yml",
             "txt", "md", "meta", "plist",
             "modulemap", "h", "cs":        return "text.document"          // 文本
        case "dll", "aar", "dylib", "jar":  return "puzzlepiece.extension"  // 插件
        case "mixer":                       return "slider.vertical.3"      // 混音台
        case "asmdef":                      return "curlybraces"            // 程序集定义
        case "bytes":                       return "text.page"              // 自定义二进制数据
        default:                            return "questionmark.text.page" // 未知类型故意用问号：提示这是个需要自己确认的可疑文件，不要改成 doc 之类的通用图标
        }
    }
    
    // MARK: - SF Symbol 缓存
    /// SF Symbol 解析结果缓存。
    /// NSImage(systemSymbolName:) 每次都要查符号表 + 新建图像，滚动时每行调一次；
    /// 图标种类只有十几种，缓存后每个符号只算一次。
    /// 安全性：本对象只被主线程使用（QL 的 delegate 回调都在主线程），无需加锁；
    /// 且 SF Symbol 是模板图，上色靠 imageView.contentTintColor，缓存不影响深浅色。
    ///
    private var symbolCache: [String: NSImage] = [:]
    
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("PackageRow")
    
    /// 取图标并缓存
    private func symbol(named name: String, pointSize: CGFloat) -> NSImage? {
        let key = "\(name)@\(pointSize)"
        if let cached = symbolCache[key] { return cached }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
                else { return nil }
        symbolCache[key] = image
        return image
    }
    
    /// 新建一行：NSTableCellView + 「图标 + 文件名」横向 stack，只建一次。
    private func makeCellView() -> NSTableCellView {
        let iconView  = NSImageView()
        let textField = NSTextField(labelWithString: "")
        textField.font          = .systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail
        // 同上：行被拖窄时允许截断，而不是和 trailing 约束冲突
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cellStack = NSStackView(views: [iconView, textField])
        cellStack.orientation = .horizontal
        cellStack.spacing     = 5
        cellStack.alignment   = .centerY
        cellStack.edgeInsets  = .init(top: 0, left: 2, bottom: 0, right: 4)  // 行内容左右内边距

        let cellView = NSTableCellView()
        cellView.identifier = Self.cellIdentifier     // ← 少了这行就不会被回收
        cellView.textField  = textField               // 供 configure 阶段访问
        cellView.imageView  = iconView

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
}
