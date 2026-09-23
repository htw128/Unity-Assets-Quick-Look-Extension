# UnityAssetsQuickLook

macOS Quick Look 扩展，让 Finder 能预览以文本形式存储的 Unity 原生资产（`.meta`、`.unitypackage` 等）。

- 仓库：https://github.com/htw128/Unity-Assets-Quick-Look-Extension （MIT，Swift，默认分支 main）
- 单人开发，直接提交到 main，无 PR 流程

---

# 构建 / 安装 / 验证

- **无测试 target，无 lint / formatter 配置** —— 没有 `xcodebuild test`；验证只有「构建成功 + 在 Finder 里按空格肉眼看」
- 构建（本机 Xcode 27 实测通过）：
  ```
  xcodebuild -project UnityAssetsQuickLook.xcodeproj -scheme Extension \
    -configuration Release -derivedDataPath /tmp/uaql-dd build
  ```
  - 唯一 scheme 是 `Extension`，但会连带构建宿主 App；产物 `<dd>/Build/Products/Release/UnityAssetsQuickLook.app`，扩展在其 `Contents/PlugIns/Extension.appex`
- 换机器 / 换 Apple ID 会签名失败：pbxproj 里**硬编码了 `DEVELOPMENT_TEAM = B3GRCQDM82`**。只验证能否编译时加 `CODE_SIGNING_ALLOWED=NO`（实测可过）
- 让扩展在 Finder 生效：`pluginkit -e use -i com.oces.UnityAssetsQuickLook.Extension`（或启动一次宿主 App），再 `qlmanage -r && qlmanage -r cache`
- `qlmanage -p <file>` 只能确认「扩展被调用」，窗口是**离屏**的；看真实效果必须在 Finder 里选中文件按空格

---

# macOS Quick Look 插件知识（实测）

- **旧式 `.qlgenerator` 已废弃**；唯一正统路线是 **Quick Look Preview Extension（`.appex`，扩展点 `com.apple.quicklook.preview`）**
- 两条实现路线：① 视图式：`NSExtensionPrincipalClass` 指向 `QLPreviewingController` 子类，可配 xib ② 数据式：`QLPreviewProvider.providePreview(for:) -> QLPreviewReply`，需 `QLIsDataBasedPreview = true`
- 生效流程：装入后 `pluginkit -a <appex>`（或启动一次宿主 App）+ `pluginkit -e use -i <bundleid>`，再 `qlmanage -r && qlmanage -r cache`
- 扩展跑在**沙盒**里，**只能读被预览的那一个文件**（QL 会先把文件复制进扩展沙盒的临时目录）
- **LaunchServices 只按扩展名判定 UTI，不嗅探内容** —— 把一个 WAV 改名成 `.unitypackage`，`mdls` 仍然报 `com.unity3d.package`，扩展照常被调用（可用来构造错误场景做测试）

## ⛔ 扩展抛错时，`errorDescription` 用户看不到（实测确认）

- 给 `Error` 加 `LocalizedError` / `errorDescription` **不等于用户能看到**
- QL 扩展的 `preparePreviewOfFile` 抛错时，QuickLookUIService 接住异常、显示**它自己的通用兜底页**（只有图标 + 文件名 + 大小 + 修改日期），**不读你的 description**
- 实测方法：把 WAV 改名为 `.unitypackage` → 扩展被调用、确实抛错、页面上一个字都没有
- **正确做法：不要抛错，改成把错误渲染成视图**（本项目已用 `PreviewNotice.make(...)` 实现）

## ⛔ Quick Look 扩展里 Process 起不来（硬结论）

- 沙盒扩展中 `Process` 启动 `/usr/bin/tar` 失败：`NSCocoaErrorDomain code=4`（ENOENT）
- **已排除"路径写错"**：`/usr/bin/tar` 是指向 `bsdtar` 的符号链接，`/usr/bin/bsdtar` 实体存在且 world-executable
- 会写系统日志（NSLog）在扩展里似乎抓不到，`log show` 各种谓词都无输出
- **沙盒容器可写**，但容器路径被 **TCC 保护**：`cat`/`python3`/`osascript`/`sudo -n` 一律 `Operation not permitted`
  - 可用通道：把结果**渲染进预览界面**，然后截屏
  - `qlmanage -p` 从终端启动时窗口是**离屏**的（window list 里 `on=0`），必须在 Finder 里按空格才会真正显示
  - 查窗口列表可用 `CGWindowListCopyWindowInfo`（写个小 Swift 脚本）

## 纯用户态解 tar.gz 的可行路线（实测可行）

| 手段 | 能否解 gzip | 能否解 tar | 结论 |
| --- | --- | --- | --- |
| **`import zlib`**（`inflateInit2` windowBits=16+15） | ✅ 原生吃 gzip，自带 CRC | ❌ 需自写 | **✅ 选用**。`<SDK>/usr/include/zlib.modulemap` 存在且被顶层 module map 声明，含 `link "z"`，**Swift 里直接 `import zlib` 即可，无需额外链接参数** |
| `Compression` framework | ⚠️ 只实现 **raw DEFLATE**（RFC 1951），不吃 gzip 容器 | ❌ | 排除 |
| `AppleArchive` | ❌ 只认自家 `.aar` | ❌ `AA_FORMAT`/`FORMAT_TAR` 零命中 | 排除 |
| `libarchive` | ✅ | ✅ | ⚠️ 可链接但 **SDK 里没有 `archive.h`** → 事实上的非公开 API |
| 自己写 ustar 解析 | — | ✅ | `<SDK>/usr/include/tar.h` 只有常量没有实现 |

**zlib 三个坑**：① `z_stream` 绝不能被复制（要用 `final class` 持有，`deinit` 里 `inflateEnd`）② `inflate` **不会**自动解拼接的多 member gzip，遇 `Z_STREAM_END` 且有剩余输入要 `inflateReset` ③ `Z_BUF_ERROR` 不是致命错误

## tar 解析必须处理的情况（真实样本实测）

- **pax 扩展头 `'x'` 是常态不是异常**：两个真实 .unitypackage 各有 483 / 489 条，必须读掉 payload 再读下一个 header。pax payload 里若出现 `path=` 键，它才是下一条目的真实名字
- **AppleDouble `._*` 伴生文件**：占真实样本条目的一半，必须过滤
- checksum 校验是发现"走偏了"最便宜的手段
- 数字字段首字节高位为 1 = GNU base-256 编码，要检测并报错；GNU 长名 `'L'/'K'` 要识别并明确拒绝
- 归档结束 = 连续两个全零块

## Unity 文件的 UTI（本机 macOS 27 实测）

| 扩展名 | 当前 UTI | 说明 |
| --- | --- | --- |
| `.meta` | `com.unity3d.meta` | **Unity 官方已声明**，接管须用 `UTImportedTypeDeclarations` |
| `.unitypackage` | `com.unity3d.package` | ⚠️ **tag 是 `unitypackage` 不是 `package`** |
| `.asset` / `.prefab` / `.unity` / `.mat` / `.anim` / `.controller` / `.mixer` | `dyn.*` | **全无主**，要接管须自己 `UTExportedTypeDeclarations` 导出 |

---

# 项目结构

## ⭐ 使用文件系统同步组（重要）

```
PBXFileSystemSynchronizedRootGroup "Extension"  (path = Extension)
    └─ membershipExceptions: Info.plist
PBXNativeTarget "Extension"
    └─ PBXSourcesBuildPhase.files = ()       ← 空；所有 .swift 在 pbxproj 里出现次数 = 0
```

- `Extension/` 目录里的任何 `.swift` **自动属于 target**，增删文件**完全不用改 `project.pbxproj`**（新增 `PreviewNoticeView.swift` 时验证过）
- **不要手改 `project.pbxproj`** —— 直接往 `Extension/` 里放文件即可
- ⚠️ 推论：**独立脚本/工具绝不能放进 `Extension/`** —— 会被自动编进扩展 target，顶层语句直接 `error: Statements are not allowed at the top level`（`Tools/` 不在任何同步组里，安全，见「回归基准」）
- 目录改名后必须同步：pbxproj 的 `INFOPLIST_FILE` / `productName` / `remoteInfo`、**xib 里的 `customModule`**、各 `.swift` 文件头注释、scheme 文件名

## 目录结构

- `Extension/`：`PreviewViewController.swift`（入口，走 xib）、`YAMLPreviewProvider.swift`、`YAMLHighlighter.swift`、`UnityPackageReader.swift`（含 GzipInflater / TarScanner / TarGzipReader + ReaderError）、`PackagePreviewProvider.swift`、`PreviewNoticeView.swift`（共用的「无法预览」提示组件）、`Info.plist`、`Base.lproj/PreviewViewController.xib`
- `UnityAssetsQuickLook/`：宿主 App，仍是 SwiftUI 空模板
- target / scheme 均为 `Extension`；扩展 bundle id `com.oces.UnityAssetsQuickLook.Extension`

## 架构要点

- `PreviewViewController.preparePreviewOfFile(at:)` **按扩展名路由**：`case "unitypackage"` → `showPackagePreview`；**`default` 兜底走 `showYAMLPreview`**
  - 推论：**只要文件能进到扩展里，任何类型都会走高亮预览** —— 加类型只需改 `Info.plist`，零 Swift 改动
- `PreviewNotice.make(symbolName:symbolDescription:title:body:)` 是共用的提示视图工厂（图标 + 标题 + 正文，居中，宽 ≤ 320）
- `ReaderError`（`UnityPackageReader.swift` 文件作用域）：`.cannotDecompress` / `.emptyArchive` / `.tooLarge` / `.malformed`

---

# 开发笔记

## ⛔ Dead Code Stripping 已验证安全

- QL 扩展的入口类在 Swift 代码里**零引用**，只被 `Info.plist` 的 principal class 和 xib 的 File's Owner 两处*字符串*引用 —— 是 `-dead_strip` 的经典风险形状
- **实测结论：没被 strip。** Release 与 Debug 的 `TtC9Extension` 符号数完全相同（都是 49），类元数据 `CMa`/`CMf`/`CMn` 都在，`_OBJC_CLASS_$__TtC9Extension21PreviewViewController` 是**已定义符号**（不是 `U`）
- 判定手法：`nm -a <二进制> | grep -E 'TtC9Extension|PreviewViewControllerC(Ma|Mn|Mf)'`，并**与 Debug 版对比数量**

### ⚠️ 静态检查的陷阱：Debug 产物是个壳

- Xcode 现在的 Debug 构建会把真实代码放进 **`Extension.debug.dylib`**，而同目录下的 `Extension` 只是个 ~56KB 的空壳（`___debug_blank_executor_main`）
- **凡是 `nm` / `strings` / `otool` 查 Debug 产物，必须查 `.debug.dylib`**，查壳会一律返回空 —— 曾差点被它骗成"被 strip 了"
- Release 没有这层，代码全在 `Extension` 里

## ⚠️ 开发时的坑

- Xcode 重启后 **tabIdentifier 会变**，用 Xcode MCP 的话每次都要重新获取
- 工作区可能有未提交的改动，回滚前先确认或单独备份，**别直接 `git checkout`**
- **改写历史后必须验证内容零变化**：先打 `git tag backup-<用途> HEAD`，改完跑 `git diff backup-<用途> main`，**输出为空才算成功**

---

# 已知待办（同步自 README Roadmap）

```
[x] 支持 `.meta` 文件
[x] 支持 `.unitypackage` 文件
[ ] 美化一下界面
[ ] 支持更多文件类型                              ← ⭐ 只改 Info.plist，零 Swift 改动，覆盖面 2 → 9 种
[ ] 多语言                                        ← 基础设施都开着，但没有 .xcstrings
[ ] 给这些资产整一个不错的图标
[ ] 让别人 clone 下来后无需调整签名配置即可直接构建
```

- 多语言前置条件已满足（错误描述现在可见了）。待抽取的硬编码中文：`YAMLPreviewProvider`（"无法预览此文件" + 二进制提示正文）、`PackagePreviewProvider`（"文件"列标题）、`UnityPackageReader`（5 条错误描述 + 5 条 malformed 原因）
- 宿主 App `ContentView.swift` 还是 `Text("Hello, world!")`；`AppIcon.appiconset` 里只有 `Contents.json`，**没有任何图片**
- README 只有几行，缺安装/构建说明和截图
- 包里每个资产的 `preview.png` 目前丢弃，未来可解出来做缩略图
- Release 功能验证未做（Release 静态符号检查已通过）

## 小瑕疵（已知晓，未处理）

- `YAMLPreviewProvider.makeBinaryNoticeView` 改成多行字符串后，正文里「不支持文本预览。」后的**空行丢了**（原为 `\n\n`，现为单个换行）
- `PreviewNoticeView.swift` 的文件头注释写的是 `//  UnityAssetsQuickLook`，同一目录其它文件都是 `//  Extension`

---

# 回归基准（tar/gzip 解析）

- `Tools/tarprobe.swift`：纯用户态解 .unitypackage 的独立 spike，曾用两个真实样本（8.6 MB）与 `tar tzf` 做过全量比对。改动 `UnityPackageReader.swift` 时用它回归
- 已实测的比对配方（样本：`~/Documents/WorkingFolder/OCESAudio-0831.unitypackage`）：
  ```
  swift Tools/tarprobe.swift <pkg>              # 归一化条目，归档顺序；LC_ALL=C sort 后 == tar tzf 结果
  swift Tools/tarprobe.swift <pkg> --pathnames  # guid<TAB>pathname，直接逐字节 == 参考
  swift Tools/tarprobe.swift <pkg> --types      # typeflag 直方图
  ```
  stdout 专供 diff，统计信息走 stderr
- 样本与金标准（`tar1/2.txt`、`out1/2.txt`、`refpn1/2.txt`、`stat1/2.txt`）都在仓库外，与本脚本原件同目录：`~/Documents/WorkingFolder/unitypackage-spike/`
- 局限：测的是**平行实现**，会与 `UnityPackageReader.swift` 漂移。更彻底的做法是抽核心 + 加 test target 直接测真实代码（未做）
