//
//  UnityPackageReader.swift
//  Extension
//
//  读取 .unitypackage，返回可直接渲染成目录树的节点。
//
//  解包走的是**纯用户态**路线：zlib 解 gzip + 手写 POSIX tar 解析。
//  为什么不用现成的方案：
//    · 子进程不可行 —— Quick Look 扩展跑在沙盒里，Process 启动 /usr/bin/tar 会失败
//      （实测 NSCocoaErrorDomain code=4 / ENOENT，而该路径本身确实存在且可执行；
//      /usr/bin/tar 是指向 bsdtar 的符号链接，实体也在）。
//    · AppleArchive 不可行 —— 它只认自家的 .aar 格式，读不了 POSIX tar；而且它的
//      FilePath 处理不了 Quick Look 传入的 file reference URL（file:///.file/id=...）。
//    · zlib 可行 —— 它是公开 SDK 的一部分（<SDK>/usr/include/zlib.modulemap 里
//      声明了 module zlib 并带 link "z"），inflateInit2 的 windowBits 加 16 即 gzip 模式，
//      CRC 校验由 zlib 自己完成。
//
//  解析逻辑与 unitypackage-spike/tarprobe.swift 保持一致。那一版已用两个真实样本
//  和 `tar tzf` 做过全量逐条比对：条目列表 diff 为空，pathname 内容逐字节一致，
//  checksum 失败 0，耗时约 80ms。
//

import Foundation
import zlib

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

// MARK: - 错误

/// 读取 .unitypackage 时可能出现的错误。
enum ReaderError: Error, LocalizedError {
    case cannotDecompress
    case emptyArchive
    case tooLarge(decompressedBytes: Int, limitBytes: Int)
    case malformed(reason: String)

    var errorDescription: String? {
        switch self {
        case .cannotDecompress:
            return "无法解压 .unitypackage 文件"
        case .emptyArchive:
            return "归档为空"
        case .tooLarge(let size, let limit):
            return "归档解压后约 \(size / 1_048_576) MB，超过 \(limit / 1_048_576) MB 的上限"
        case .malformed(let reason):
            return "归档格式异常：\(reason)"
        }
    }
}

// MARK: - zlib 常量

// zlib 的 #define 在这里显式落成 Swift 常量，避开宏导入的不确定性。
private let kZOK: Int32 = 0
private let kZStreamEnd: Int32 = 1
private let kZBufError: Int32 = -5
private let kZNoFlush: Int32 = 0
/// 16 = 只解 gzip 容器；+15 = MAX_WBITS。见 zlib.h 中 inflateInit2 的说明。
private let kGzipWindowBits: Int32 = 16 + 15
private let kOutChunk = 1 << 20

// MARK: - gzip 解压

/// gzip 解压器。
///
/// 用 final class 持有 z_stream：**绝不能让 z_stream 作为 struct 被复制** ——
/// init 之后发生拷贝会让 next_in/next_out 指向旧内存。
private final class GzipInflater {

    private var stream = z_stream()
    private var ready = false

    init() throws {
        let rc = inflateInit2_(&stream, kGzipWindowBits, zlibVersion(),
                               Int32(MemoryLayout<z_stream>.size))
        guard rc == kZOK else { throw ReaderError.cannotDecompress }
        ready = true
    }

    deinit {
        if ready { inflateEnd(&stream) }
    }

    /// 解压到内存。输出超过 limit 字节时立刻抛 .tooLarge。
    func gunzip(_ input: Data, limit: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(min(limit, max(input.count * 3, 1 << 20)))
        var outBuf = [UInt8](repeating: 0, count: kOutChunk)

        try input.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            // next_in 是非 const 的 UnsafeMutablePointer<Bytef>!，需要手动转换
            stream.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(input.count)

            while true {
                var produced = 0
                let rc: Int32 = outBuf.withUnsafeMutableBufferPointer { outPtr -> Int32 in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(kOutChunk)
                    let r = zlib.inflate(&stream, kZNoFlush)
                    produced = kOutChunk - Int(stream.avail_out)
                    return r
                }

                if produced > 0 {
                    out.append(contentsOf: outBuf[0..<produced])
                    if out.count > limit {
                        throw ReaderError.tooLarge(decompressedBytes: out.count, limitBytes: limit)
                    }
                }

                switch rc {
                case kZStreamEnd:
                    // inflate 不会自动解拼接的多 member gzip，需自己 reset 后继续喂
                    if stream.avail_in == 0 { return }
                    guard inflateReset(&stream) == kZOK else {
                        throw ReaderError.cannotDecompress
                    }

                case kZOK, kZBufError:
                    // Z_BUF_ERROR 不是致命错误：输出缓冲满或输入耗尽而已
                    if produced == 0 && stream.avail_in == 0 { return }

                default:
                    throw ReaderError.cannotDecompress
                }
            }
        }

        return out
    }
}

// MARK: - tar 扫描

/// POSIX tar（ustar）扫描器：逐 512 字节块行走，挑出 guid → pathname 映射。
private enum TarScanner {

    /// 扫描归档，返回 `<guid>: <Unity 项目内路径>`。
    static func pathnames(in b: [UInt8]) throws -> [String: String] {
        var result: [String: String] = [:]
        var offset = 0
        var pendingPath: String?

        while offset + 512 <= b.count {

            if isZeroBlock(b, offset) { break }     // 归档结束；容忍缺尾块

            // checksum 校验：发现"走偏了"最便宜的手段
            let stored = try octal(b, offset + 148, 8, "chksum", offset)
            let (uSum, sSum) = checksum(b, offset)
            guard Int(uSum) == stored || Int(sSum) == stored else {
                throw ReaderError.malformed(reason: "tar 头部校验和不匹配（偏移 \(offset)）")
            }

            let size = try octal(b, offset + 124, 12, "size", offset)
            let typeflag = b[offset + 156]

            switch typeflag {
            case 0x78, 0x67:
                // 'x' pax 扩展头 / 'g' pax 全局头。
                // 必须读掉 payload 再读下一个 header，否则整体错位 ——
                // 真实样本里这是常态（各 483 / 489 条），不是异常路径。
                if typeflag == 0x78, let p = parsePax(slice(b, offset + 512, size))["path"] {
                    pendingPath = p                 // pax 覆盖下一条目的真实名字
                }
                offset += 512 + roundUp512(size)
                continue

            case 0x4C, 0x4B:
                // 'L' GNU 长名 / 'K' GNU 长链接：识别出来但明确拒绝，不静默算错
                throw ReaderError.malformed(reason: "不支持 GNU 长名扩展头")

            default:
                break
            }

            var name = rawName(b, offset)
            if let p = pendingPath { name = p; pendingPath = nil }

            let isDir = (typeflag == 0x35) || name.hasSuffix("/")

            // 只关心 `<guid>/pathname` 这种小文本条目：
            // 这一条判断同时天然过滤掉了 macOS 的 AppleDouble `._*` 伴生文件
            // （它们在真实样本里占了足足一半的条目）。
            if !isDir, size > 0, size < 65_536 {
                let parts = name.split(separator: "/").filter { $0 != "." }
                if parts.count == 2, parts[1] == "pathname",
                   !parts[0].hasPrefix("._") {
                    let content = String(decoding: slice(b, offset + 512, size), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        result[String(parts[0])] = content
                    }
                }
            }

            offset += 512 + roundUp512(size)
        }

        return result
    }

    // MARK: 字段读取

    private static func isZeroBlock(_ b: [UInt8], _ off: Int) -> Bool {
        guard off + 512 <= b.count else { return false }
        for i in 0..<512 where b[off + i] != 0 { return false }
        return true
    }

    private static func roundUp512(_ n: Int) -> Int { (n + 511) / 512 * 512 }

    private static func slice(_ b: [UInt8], _ start: Int, _ len: Int) -> ArraySlice<UInt8> {
        let s = min(start, b.count)
        let e = min(start + len, b.count)
        return b[s..<e]
    }

    private static func cstr(_ b: [UInt8], _ start: Int, _ maxLen: Int) -> String {
        guard start < b.count else { return "" }
        var end = start
        let limit = min(start + maxLen, b.count)
        while end < limit && b[end] != 0 { end += 1 }
        return String(decoding: b[start..<end], as: UTF8.self)
    }

    private static func rawName(_ b: [UInt8], _ off: Int) -> String {
        let n = cstr(b, off, 100)
        let prefix = cstr(b, off + 345, 155)        // ustar prefix 字段
        return prefix.isEmpty ? n : prefix + "/" + n
    }

    /// chksum 字段当 8 个空格，做 unsigned 求和（失败再试 signed 变体）。
    private static func checksum(_ b: [UInt8], _ off: Int) -> (UInt32, Int32) {
        var u: UInt32 = 0
        var s: Int32 = 0
        for i in 0..<512 {
            let byte: UInt8 = (i >= 148 && i < 156) ? 0x20 : b[off + i]
            u = u &+ UInt32(byte)
            s = s &+ Int32(Int8(bitPattern: byte))
        }
        return (u, s)
    }

    private static func octal(_ b: [UInt8], _ start: Int, _ len: Int,
                              _ field: String, _ off: Int) throws -> Int {
        var i = start
        let end = min(start + len, b.count)
        while i < end && (b[i] == 0x20 || b[i] == 0) { i += 1 }
        if i < end && (b[i] & 0x80) != 0 {          // 首字节高位为 1 = GNU base-256
            throw ReaderError.malformed(reason: "字段 \(field) 使用了 GNU base-256 编码")
        }
        var v = 0
        while i < end {
            let c = b[i]
            if c == 0 || c == 0x20 { break }
            guard c >= 0x30, c <= 0x37 else {
                throw ReaderError.malformed(reason: "字段 \(field) 不是合法八进制")
            }
            v = v &* 8 &+ Int(c - 0x30)
            i += 1
        }
        return v
    }

    /// pax 记录格式：`<十进制长度> <key>=<value>\n`
    private static func parsePax(_ payload: ArraySlice<UInt8>) -> [String: String] {
        let bytes = Array(payload)
        var out: [String: String] = [:]
        var i = 0

        while i < bytes.count {
            var len = 0
            var j = i
            while j < bytes.count, bytes[j] >= 0x30, bytes[j] <= 0x39 {
                len = len * 10 + Int(bytes[j] - 0x30)
                j += 1
            }
            guard j < bytes.count, bytes[j] == 0x20, len > 0, i + len <= bytes.count else { break }

            let recStart = j + 1
            var recEnd = i + len
            if recEnd > recStart, bytes[recEnd - 1] == 0x0A { recEnd -= 1 }

            if recEnd > recStart {
                var k = recStart
                while k < recEnd, bytes[k] != 0x3D { k += 1 }
                if k < recEnd {
                    out[String(decoding: bytes[recStart..<k], as: UTF8.self)] =
                        String(decoding: bytes[(k + 1)..<recEnd], as: UTF8.self)
                }
            }
            i += len
        }

        return out
    }
}

// MARK: - 解包器

/// 从 .unitypackage 中读出 guid → Unity 项目路径 的映射。
///
/// .unitypackage 是 gzip 压缩的 tar：每个资产占一个 `<guid>/` 目录，
/// 目录里的 `pathname` 文件记录该资产在 Unity 项目中的完整路径。
struct TarGzipReader {

    /// 解压后大小的上限。超过就拒绝预览，避免把 Quick Look 的内存吃爆。
    static let decompressedLimit = 256 * 1_048_576

    func pathnames(in data: Data) throws -> [String: String] {
        guard data.count >= 2 else { throw ReaderError.emptyArchive }

        let magic = [UInt8](data.prefix(2))
        guard magic[0] == 0x1F, magic[1] == 0x8B else {
            throw ReaderError.malformed(reason: "不是 gzip 数据")
        }

        // gzip 尾部最后 4 字节是 ISIZE（解压后大小 mod 2^32），解压前就能读到，
        // 用它做一次快速拒绝。真正的兜底是解压过程中对输出长度实时设限。
        if let hint = Self.decompressedSizeHint(data), hint > Self.decompressedLimit {
            throw ReaderError.tooLarge(decompressedBytes: hint,
                                       limitBytes: Self.decompressedLimit)
        }

        let plain = try GzipInflater().gunzip(data, limit: Self.decompressedLimit)
        guard !plain.isEmpty else { throw ReaderError.emptyArchive }

        let map = try TarScanner.pathnames(in: plain)
        guard !map.isEmpty else { throw ReaderError.emptyArchive }
        return map
    }

    /// 读 gzip 尾部的 ISIZE 字段。
    ///
    /// 注意它按 2^32 取模，超过 4GB 的归档会失真 —— 所以它只是快速预检，不是唯一防线。
    private static func decompressedSizeHint(_ data: Data) -> Int? {
        let tail = [UInt8](data.suffix(4))
        guard tail.count == 4 else { return nil }
        let v = UInt32(tail[0])
            | UInt32(tail[1]) << 8
            | UInt32(tail[2]) << 16
            | UInt32(tail[3]) << 24
        return Int(v)
    }
}

// MARK: - 读取器

struct UnityPackageReader {

    // MARK: - 公开接口

    /// 读取 .unitypackage，返回目录树根节点。
    ///
    /// 策略：
    ///   1. 用 Data(contentsOf:) 读取文件（能正确处理 file reference URL 和安全作用域 URL）
    ///   2. 纯用户态解包：zlib 解 gzip → 扫描 tar → 取出所有 pathname
    ///   3. 组装目录树
    ///
    /// 全程不落盘、不起子进程 —— 沙盒里唯一走得通的路线。
    func read(from url: URL) throws -> PackageNode {

        // Data(contentsOf:) 能正确解析 file reference URL（file:///.file/id=...），
        // 这正是当初 AppleArchive 的 FilePath 栽跟头的地方。
        let data = try Data(contentsOf: url)

        // 解包 + 取路径映射，全部在内存里完成
        let guidToPath = try TarGzipReader().pathnames(in: data)

        // 组装目录树
        return buildTree(from: guidToPath)
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
