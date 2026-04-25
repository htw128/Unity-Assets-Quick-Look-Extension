//
//  UnityPackageReader.swift
//  Exntension
//

import Foundation

// MARK: - 数据模型

/// 代表 .unitypackage 内部目录树的一个节点。
final class PackageNode {

    let name: String        // 显示名称（路径最后一段，如 "Textures" 或 "MyMaterial.mat"）
    let fullPath: String?   // Unity 项目中的完整路径，只有叶子节点（文件）才有值
    var children: [PackageNode] = []

    /// 有子节点，或者没有 fullPath，就视为文件夹
    var isDirectory: Bool { !children.isEmpty || fullPath == nil }

    init(name: String, fullPath: String? = nil) {
        self.name     = name
        self.fullPath = fullPath
    }
}

// MARK: - 读取器

struct UnityPackageReader {

    // MARK: - 错误类型

    enum ReaderError: Error, LocalizedError {
        case cannotDecompress
        case emptyArchive

        var errorDescription: String? {
            switch self {
            case .cannotDecompress: return "无法解压 .unitypackage 文件"
            case .emptyArchive:     return "归档为空"
            }
        }
    }

    // MARK: - 公开接口

    /// 读取 .unitypackage，返回目录树根节点。
    ///
    /// 策略：
    ///   1. 用 Data(contentsOf:) 读取文件（能正确处理 file reference URL 和安全作用域 URL）
    ///   2. 写入临时文件
    ///   3. 用 tar 命令行工具解压到临时目录
    ///   4. 扫描 pathname 文件，构建目录树
    func read(from url: URL) throws -> PackageNode {

        // 临时目录：解压目标
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unitypackage-\(UUID().uuidString)")

        // 临时文件：存放从内存写入的归档数据
        let tempArchive = FileManager.default.temporaryDirectory
            .appendingPathComponent("unitypackage-\(UUID().uuidString).tar.gz")

        // 无论成功或失败，都清理临时文件
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: tempArchive)
        }

        // 第一步：用 Foundation API 读取文件
        // Data(contentsOf:) 能正确解析 file reference URL（file:///.file/id=...），
        // 而 AppleArchive 的 FilePath 无法处理这种 URL。
        let data = try Data(contentsOf: url)

        // 第二步：写入临时文件，供 tar 命令使用
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try data.write(to: tempArchive)

        // 第三步：用 tar 解压
        // .unitypackage 是标准的 tar.gz 格式，macOS 自带 tar 能正确处理。
        try runTar(archive: tempArchive, destination: tempDir)

        // 第四步：扫描 pathname 文件，构建路径映射
        let guidToPath = try readPathnames(from: tempDir)

        // 第五步：组装目录树
        return buildTree(from: guidToPath)
    }

    // MARK: - tar 解压

    /// 用系统 tar 命令解压 .tar.gz 文件。
    ///
    /// 为什么用 tar 而不是 AppleArchive？
    ///   AppleArchive 的 ArchiveByteStream.fileStream 依赖 FilePath，
    ///   而 Quick Look 传入的 URL 可能是 file reference URL（file:///.file/id=...），
    ///   FilePath 无法正确解析这种 URL，导致 "Invalid/non-supported archive stream" 错误。
    ///   tar 命令接受 POSIX 路径，不受此限制。
    private func runTar(archive: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "-xzf", archive.path,   // -xzf: 解压 gzip 压缩的归档
            "-C", destination.path,  // -C: 切换到目标目录
        ]

        // 捕获 stderr 输出，方便出错时定位问题
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(data: errorPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            NSLog("tar failed (exit %d): %@", process.terminationStatus, errorOutput)
            throw ReaderError.cannotDecompress
        }
    }

    // MARK: - 扫描 pathname 文件

    /// 扫描解压后的临时目录，读取所有 pathname 文件，返回 GUID → Unity路径 的映射。
    ///
    /// 解压后的目录结构：
    ///   <tempDir>/
    ///     <GUID>/
    ///       pathname      ← 一行文本，内容是 Unity 项目中的路径
    ///       asset         ← 资产实体（我们不需要）
    ///       asset.meta    ← 元数据（我们不需要）
    private func readPathnames(from directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]

        let items = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )

        for guidDir in items {
            guard (try? guidDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            let pathnameFile = guidDir.appendingPathComponent("pathname")

            guard let content = try? String(contentsOf: pathnameFile, encoding: .utf8) else {
                continue
            }

            let trimmed = content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            if !trimmed.isEmpty {
                result[guidDir.lastPathComponent] = trimmed
            }
        }

        return result
    }

    // MARK: - 树构建

    /// 把 GUID → 路径 的映射转换成目录树。
    private func buildTree(from guidToPath: [String: String]) -> PackageNode {
        let root = PackageNode(name: "/")

        for fullPath in guidToPath.values.sorted() {
            let segments = fullPath.split(separator: "/").map(String.init)
            guard !segments.isEmpty else { continue }
            insert(segments: segments, fullPath: fullPath, into: root)
        }

        return root
    }

    /// 递归地把路径段插入树中。
    private func insert(segments: [String], fullPath: String, into node: PackageNode) {
        guard let first = segments.first else { return }
        let remaining = Array(segments.dropFirst())

        if remaining.isEmpty {
            node.children.append(PackageNode(name: first, fullPath: fullPath))
        } else {
            if let existing = node.children.first(where: { $0.name == first && $0.isDirectory }) {
                insert(segments: remaining, fullPath: fullPath, into: existing)
            } else {
                let folder = PackageNode(name: first)
                node.children.append(folder)
                insert(segments: remaining, fullPath: fullPath, into: folder)
            }
        }
    }
}
