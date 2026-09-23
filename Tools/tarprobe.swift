// tarprobe.swift — 验证「纯用户态能否解开 .unitypackage」
//
// 用法：
//   swift tarprobe.swift <file.unitypackage>               # stdout: 归一化条目列表（用于 diff）
//   swift tarprobe.swift <file.unitypackage> --pathnames    # stdout: guid<TAB>pathname
//   swift tarprobe.swift <file.unitypackage> --types        # stdout: typeflag 直方图
//
// stdout 专供与 `tar tzf` 对比；统计信息一律走 stderr。
//
// 本脚本自身就是"可行性证明"的一部分，三条硬约束：
//   · 不启动任何子进程（不 import Foundation 的 Process，全文无 Process/NSTask）
//   · 不调用任何非公开 API（只用公开 SDK 的 zlib）
//   · 不写任何文件（无 FileManager 写操作，只读 mappedIfSafe）

import Foundation
import zlib

// MARK: - 错误

enum ProbeError: Error, CustomStringConvertible {
    case cannotRead(String)
    case inflateInit(Int32)
    case inflateFailed(Int32, String?)
    case notGzip(UInt8, UInt8)
    case tarBase256(String, Int)
    case tarBadOctal(String, Int, String)
    case unsupportedLongName(Int)

    var description: String {
        switch self {
        case .cannotRead(let p):                return "无法读取: \(p)"
        case .inflateInit(let rc):              return "inflateInit2 失败 rc=\(rc)"
        case .inflateFailed(let rc, let m):     return "inflate 失败 rc=\(rc) msg=\(m ?? "-")"
        case .notGzip(let a, let b):            return String(format: "非 gzip 数据 (magic %02x %02x)", a, b)
        case .tarBase256(let f, let o):         return "\(f)@\(o) 为 GNU base-256 编码（不支持）"
        case .tarBadOctal(let f, let o, let r): return "\(f)@\(o) 非法八进制: \(r)"
        case .unsupportedLongName(let o):       return "偏移 \(o) 处出现 GNU 长名扩展头（不支持）"
        }
    }
}

// zlib 的 #define 常量显式落成 Swift 常量，避开宏导入的不确定性
private let kZOK: Int32 = 0
private let kZStreamEnd: Int32 = 1
private let kZBufError: Int32 = -5
private let kZNoFlush: Int32 = 0
private let kGzipWindowBits: Int32 = 16 + 15   // 16 = 仅 gzip；+15 = MAX_WBITS（见 zlib.h:871-876）

// MARK: - gzip 解压（zlib，内存内）

/// 用 final class 持有 z_stream。
/// 绝不能让 z_stream 作为 struct 被复制 —— init 之后拷贝会让 next_in/next_out 指向旧内存。
final class GzipInflater {
    private var stream = z_stream()
    private var ready = false
    private(set) var memberCount = 0

    init() throws {
        let rc = inflateInit2_(&stream, kGzipWindowBits, zlibVersion(),
                               Int32(MemoryLayout<z_stream>.size))
        guard rc == kZOK else { throw ProbeError.inflateInit(rc) }
        ready = true
    }

    deinit {
        if ready { inflateEnd(&stream) }
    }

    func gunzip(_ input: [UInt8]) throws -> [UInt8] {
        let outChunk = 1 << 20
        var out = [UInt8]()
        out.reserveCapacity(input.count * 3)
        var outBuf = [UInt8](repeating: 0, count: outChunk)

        try input.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            // next_in 是非 const 的 UnsafeMutablePointer<Bytef>!，需手动转换
            stream.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(input.count)

            while true {
                var produced = 0
                let rc: Int32 = outBuf.withUnsafeMutableBufferPointer { outPtr -> Int32 in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(outChunk)
                    let r = zlib.inflate(&stream, kZNoFlush)
                    produced = outChunk - Int(stream.avail_out)
                    return r
                }

                if produced > 0 { out.append(contentsOf: outBuf[0..<produced]) }

                switch rc {
                case kZStreamEnd:
                    memberCount += 1
                    // inflate 不会自动解拼接的多 member gzip，需自己 reset 后继续
                    if stream.avail_in == 0 { return }
                    let rr = inflateReset(&stream)
                    guard rr == kZOK else { throw ProbeError.inflateFailed(rr, "inflateReset") }

                case kZOK, kZBufError:
                    // Z_BUF_ERROR 不是致命错误：输出缓冲满或输入耗尽而已
                    if produced == 0 && stream.avail_in == 0 { return }

                default:
                    let msg = stream.msg.map { String(cString: $0) }
                    throw ProbeError.inflateFailed(rc, msg)
                }
            }
        }
        return out
    }
}

// MARK: - tar 扫描

struct TarEntry {
    let name: String
    let size: Int
    let typeflag: UInt8
    let offset: Int
    let content: [UInt8]?      // 仅 pathname 条目保留内容
}

struct TarStats {
    var blocks = 0
    var typeHistogram: [UInt8: Int] = [:]
    var checksumFailures: [String] = []
    var paxPathOverrides = 0
    var trailingZeroBlocks = 0
}

enum TarScanner {

    static func scan(_ b: [UInt8]) throws -> (entries: [TarEntry], stats: TarStats) {
        var entries: [TarEntry] = []
        var stats = TarStats()
        var offset = 0
        var pendingPath: String?

        while offset + 512 <= b.count {

            if isZeroBlock(b, offset) {
                var zeros = 0
                var probe = offset
                while probe + 512 <= b.count && isZeroBlock(b, probe) {
                    zeros += 1
                    probe += 512
                }
                stats.trailingZeroBlocks = zeros
                break                                   // 归档结束（容忍缺尾块）
            }

            stats.blocks += 1

            // —— checksum 校验：发现"走偏了"最便宜的手段
            let stored = try octal(b, offset + 148, 8, "chksum", offset)
            let (uSum, sSum) = checksum(b, offset)
            if Int(uSum) != stored && Int(sSum) != stored {
                stats.checksumFailures.append(
                    "\(rawName(b, offset))@\(offset) 存=\(stored) 算=\(uSum)/\(sSum)")
            }

            let size = try octal(b, offset + 124, 12, "size", offset)
            let typeflag = b[offset + 156]
            stats.typeHistogram[typeflag, default: 0] += 1

            var entryName = rawName(b, offset)

            switch typeflag {
            case 0x78, 0x67:                            // 'x' pax 扩展头 / 'g' pax 全局头
                // 必须读掉 payload 再读下一个 header，绝不能当成文件条目（否则整体错位）
                if typeflag == 0x78 {
                    let attrs = parsePax(slice(b, offset + 512, size))
                    if let p = attrs["path"] {          // pax "跳过"唯一的正确性漏洞
                        pendingPath = p
                        stats.paxPathOverrides += 1
                    }
                }
                offset += 512 + roundUp512(size)
                continue

            case 0x4C, 0x4B:                            // 'L' GNU 长名 / 'K' GNU 长链接
                throw ProbeError.unsupportedLongName(offset)

            default:
                break
            }

            if let p = pendingPath { entryName = p; pendingPath = nil }

            let isDir = (typeflag == 0x35) || entryName.hasSuffix("/")
            let name = isDir ? String(entryName.dropLast()) : entryName

            // 只给 pathname 小文件留内容（上限 64KB，避免整包缓冲膨胀）
            let isPathname = (typeflag == 0x30 || typeflag == 0x00)
                && name.hasSuffix("pathname") && size > 0 && size < 65536
            let content: [UInt8]? = isPathname ? Array(slice(b, offset + 512, size)) : nil

            entries.append(TarEntry(name: name, size: size, typeflag: typeflag,
                                    offset: offset, content: content))
            offset += 512 + roundUp512(size)
        }

        return (entries, stats)
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
        let prefix = cstr(b, off + 345, 155)            // ustar prefix 字段
        return prefix.isEmpty ? n : prefix + "/" + n
    }

    /// chksum 字段当 8 个空格，做 unsigned 求和（失败再试 signed 变体）
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
        if i < end && (b[i] & 0x80) != 0 {              // 首字节高位为 1 = GNU base-256
            throw ProbeError.tarBase256(field, off)
        }
        var v = 0
        while i < end {
            let c = b[i]
            if c == 0 || c == 0x20 { break }
            guard c >= 0x30, c <= 0x37 else {
                throw ProbeError.tarBadOctal(field, off, String(decoding: b[start..<end], as: UTF8.self))
            }
            v = v &* 8 &+ Int(c - 0x30)
            i += 1
        }
        return v
    }

    /// pax 记录格式："<十进制长度> <key>=<value>\n"
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

// MARK: - 归一化

/// 去掉前导 "./"、尾部 "/"、根条目，丢掉任一路径段以 "._" 开头的条目（AppleDouble）
func normalize(_ name: String) -> String? {
    var n = name
    while n.hasPrefix("./") { n = String(n.dropFirst(2)) }
    while n.hasSuffix("/") { n = String(n.dropLast()) }
    if n.isEmpty { return nil }
    let segs = n.split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)
        .filter { $0 != "." }                       // 丢弃 "." 段（根条目本身）
    if segs.isEmpty { return nil }                  // 根条目 "." 归一化后为空 → 丢弃
    if segs.contains(where: { $0.hasPrefix("._") }) { return nil }
    return segs.joined(separator: "/")
}

// MARK: - main

let argv = CommandLine.arguments
let errPipe = FileHandle.standardError
func err(_ s: String) { errPipe.write(Data((s + "\n").utf8)) }

guard argv.count >= 2 else {
    err("用法: swift tarprobe.swift <file.unitypackage> [--pathnames|--types]")
    exit(2)
}
let filePath = argv[1]
let mode = argv.count >= 3 ? argv[2] : ""

let t0 = Date()
guard let rawData = try? Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe) else {
    err("无法读取 \(filePath)")
    exit(1)
}
let compressed = [UInt8](rawData)
let tRead = Date()

do {
    guard compressed.count >= 2, compressed[0] == 0x1F, compressed[1] == 0x8B else {
        throw ProbeError.notGzip(compressed.first ?? 0, compressed.count > 1 ? compressed[1] : 0)
    }

    let inflater = try GzipInflater()
    let plain = try inflater.gunzip(compressed)
    let tInflate = Date()

    let (entries, stats) = try TarScanner.scan(plain)
    let tScan = Date()

    // 归一化 + 提取 pathname
    var normalized: [String] = []
    var pathnames: [(guid: String, path: String)] = []
    for e in entries {
        guard let n = normalize(e.name) else { continue }
        normalized.append(n)
        if let c = e.content {
            let segs = n.split(separator: "/").map(String.init)
            if segs.count == 2, segs[1] == "pathname" {
                pathnames.append((segs[0],
                                  String(decoding: c, as: UTF8.self)
                                    .trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    // ——— stdout（模式相关）———
    switch mode {
    case "--pathnames":
        for (g, p) in pathnames.sorted(by: { $0.guid < $1.guid }) {
            print("\(g)\t\(p)")
        }
    case "--types":
        for (t, c) in stats.typeHistogram.sorted(by: { $0.key < $1.key }) {
            let ch = (t >= 0x20 && t < 0x7F) ? String(UnicodeScalar(t)) : String(format: "\\x%02x", t)
            print("\(ch)\t\(c)")
        }
    default:
        for n in normalized { print(n) }
    }

    // ——— stderr（统计）———
    let histoLine = stats.typeHistogram.sorted { $0.key < $1.key }.map { k, v -> String in
        let ch = (k >= 0x20 && k < 0x7F) ? String(UnicodeScalar(k)) : String(format: "\\x%02x", k)
        return "\(ch)=\(v)"
    }.joined(separator: " ")

    err("")
    err("=== tarprobe 统计 ===")
    err("文件            \(filePath)")
    err("压缩大小        \(compressed.count) B")
    err("解压大小        \(plain.count) B")
    err("gzip member 数  \(inflater.memberCount)")
    err("tar 块数        \(stats.blocks)")
    err("typeflag 直方图 \(histoLine)")
    err("checksum 失败   \(stats.checksumFailures.count)")
    for f in stats.checksumFailures.prefix(5) { err("                · \(f)") }
    err("pax path= 覆盖  \(stats.paxPathOverrides)")
    err("尾部零块        \(stats.trailingZeroBlocks)")
    err("条目总数        \(entries.count)")
    err("归一化后        \(normalized.count)")
    err("pathname 条目   \(pathnames.count)")
    err(String(format: "耗时            读 %.3fs / 解压 %.3fs / 扫描 %.3fs / 合计 %.3fs",
               tRead.timeIntervalSince(t0),
               tInflate.timeIntervalSince(tRead),
               tScan.timeIntervalSince(tInflate),
               tScan.timeIntervalSince(t0)))
    err("")

} catch {
    err("失败: \(error)")
    exit(1)
}
