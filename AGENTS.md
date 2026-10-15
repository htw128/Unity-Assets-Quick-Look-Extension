# UnityAssetsQuickLook

macOS Quick Look 扩展，让 Finder 能预览以文本形式存储的 Unity 原生资产（`.meta`、`.unitypackage` 等）。

- 仓库：https://github.com/htw128/Unity-Assets-Quick-Look-Extension （MIT，Swift，默认分支 main）
- 单人开发，直接提交到 main，无 PR 流程

---

# ⭐ 协作偏好：面向学习者的「精确定位式」讲解

用户正在**通过本项目学习 macOS / Swift 开发**，因此对每个需求，回复必须是**精确到文件和位置的操作指南**，而不是笼统的方向性描述：

- **明确「改哪个文件」**：给出完整相对路径（如 `Extension/PreviewViewController.swift`）
- **明确「改哪里」**：指出函数名 / 类名 / 行号范围或原文片段，说明定位依据
- **明确「改成什么」**：给出可直接落地的代码片段，而非伪代码
- **说明「为什么」**：解释该改动涉及的 API、原理、坑（本项目已积累大量实测结论，见下文各节）
- 反例（不要这样写）：❌「在路由逻辑里加一个 case 即可」——应写成 ✅「在 `Extension/PreviewViewController.swift` 的 `preparePreviewOfFile(at:)` 里那个 `switch` 的 `case "unitypackage"` 旁新增 `case "xxx":`」

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

样本：`testfiles/` 下 5 个可解析包 + 2 个异常包，覆盖三种来源（见文末「测试样本清单」）。**下面每条都标了它在哪些样本上成立** —— 别把 Mac 包的特性当成通用前提。

- **条目名可能带 `./` 前缀，也可能不带** —— Mac 导出的两个包几乎全是 `./<guid>/asset`（实测 964 / 966 条带前缀，两个例外是根条目 `.` 和它自己的 AppleDouble `._.`），Windows 包与两个 Unity 官方 TMP 包则 **0 条**带前缀。解析器必须对两者归一化：不能假定前缀存在，也不能拿 `^\./` 当白名单
- **pax 扩展头 `'x'` 是常态不是异常**：Mac 导出的两个真实 .unitypackage 各有 483 / 489 条，必须读掉 payload 再读下一个 header。pax payload 里若出现 `path=` 键，它才是下一条目的真实名字（本样本实测 `path=` 出现 0 次）
  - ⚠️ **但不能假定它一定存在**：Windows 包与两个 TMP 包 pax 头数均为 **0**
- **AppleDouble `._*` 伴生文件**：Mac 导出的两个真实样本里各占条目总数的一半（483/966、489/978），**与真实条目 1:1**，必须过滤。实测有三种形态：`./._<guid>`（130 个，配 guid 目录）、`./<guid>/._asset|._pathname|._asset.meta`（352 个，配目录内的文件）、根条目自己的 `._.`（1 个）
  - Windows 包与两个 TMP 包为 **0 个** —— 过滤逻辑只对 Mac 系包生效，**不要拿它的存在与否判断"输入是否正常"**
- **header magic 有两种，都不是错误格式**：
  - POSIX ustar（`ustar\0` + version `00`）：两个 Mac 包、两个 TMP 包
  - **GNU oldgnu（`ustar␠␠\0`）**：Windows 包实测，需正常解析
- **typeflag 实测只出现 `'0'`（文件，835 条）与 `'5'`（目录，131 条）**，本批样本无 `'L'/'K'` 长名；但 `UnityPackageReader.swift` 对 GNU 长名**仍显式拒绝**，这是有意的防御，别删
- **文件夹在 guid 目录里没有 `asset` 条目** —— 这是判「文件 / 文件夹」唯一可靠的信号：
  - 实测 `real.unitypackage`：130 个 guid = 95 个有 `asset`（文件）+ 35 个没有（文件夹），零反例
  - ⚠️ **别用 `asset.meta` 里的 `folderAsset: yes`**：35 个文件夹里只有 28 个写了这个键，单用会漏掉 7 个
  - 无代码的交叉验证：`grep -cE '/asset$'` = 文件数（95），`grep -cE '/pathname$'` = 文件 + 文件夹（130），两者之差 = 文件夹数（35）
  - 推论：**文件夹本身也有 `pathname` 条目**，而且字典序一定排在它的子文件之前 —— 建树时若用「有没有子节点」判断是不是目录，会给每个文件夹多造一个同名空节点（表现为「多出一行没有扩展名的文件，图标是问号」）
- **数字字段实测全是 ASCII**，未出现 base-256；但保留「首字节高位为 1 即 base-256，检测并报错」的防御
- checksum 校验是发现"走偏了"最便宜的手段
- 归档结束 = 连续两个全零块

## ⛔ 参照工具陷阱：macOS 的 `tar` 会静默隐藏 AppleDouble

- **`/usr/bin/tar` 是 bsdtar（libarchive）**。macOS 上 `process_mac_extensions` 默认开启 → 归档里的 `._*` 条目被当作扩展属性（xattr）消费掉：**列目录看不到、解包也不落地、`archive_error_string` 为空**。不报错、不留痕
  - 上游对成因的说明（不是我们推断的）：`is_mac_metadata_entry()` **只按 basename 匹配 `._foo`**，从不检查后面有没有对应实体条目 —— 见 libarchive/libarchive#3310；格式说明见 libarchive wiki `TarExtendedAttributes` 的 "Apple tar" 一节
- 同一个 `real.unitypackage`，三种数法：

  | 命令 | 条目数 |
  | --- | ---: |
  | `tar tzf \| wc -l` | 483 ← 少了全部 AppleDouble |
  | `tar --options '!mac-ext' -tf …` | 966 ← 完整视图 |
  | `python3 -c "…tarfile.getnames()"` | 966 |

- **判据**：任何时候怀疑"归档里有没有 `._`"，**不能只听 bsdtar 的** —— 用 `tar --options '!mac-ext'` 或 Python `tarfile` 交叉验证
- 实测环境：macOS 27 自带 `/usr/bin/tar`（bsdtar）；`--options '!mac-ext'` 这个开关在本机可用，**这正是它比 `tar tzf` 更适合当参照的原因**

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
[x] 美化一下界面
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

- `Tools/tarprobe.swift`：纯用户态解 .unitypackage 的独立 spike，曾用真实样本与 `tar tzf` 做过全量比对。改动 `UnityPackageReader.swift` 时用它回归
- 已实测的比对配方（样本：`testfiles/real.unitypackage`；该目录**尚未入库**，见文末「测试样本清单」）：
  ```
  # 参考基准：不能直接用 `tar tzf`（它会静默吞掉 ._* 条目，见「参照工具陷阱」一节）
  #   sed 去 ./ 前缀与尾斜杠；grep 显式过滤 AppleDouble 与根条目，让"过滤"成为被测对象自己的行为
  tar --options '!mac-ext' -tf <pkg> | sed 's|^\./||; s|/$||' | grep -vE '(^|/)\._' | grep -vE '^\.?$' | LC_ALL=C sort
  swift Tools/tarprobe.swift <pkg>              # 归一化条目，归档顺序；LC_ALL=C sort 后 == 上面这条参考
  swift Tools/tarprobe.swift <pkg> --pathnames  # guid<TAB>pathname，直接逐字节 == 参考
  swift Tools/tarprobe.swift <pkg> --types      # typeflag 直方图
  ```
  stdout 专供 diff，统计信息走 stderr
  - ✅ 已实测：`real`（482 行）、`windows`（331 行）、`TMP Essential Resources`（158 行）三个样本，上面这条参考与 tarprobe 输出 **diff 均为 0 行**
- ⚠️ **基准的共模盲区（务必看）**：`tar tzf` 静默隐藏 `._*`，而 `TarScanner` 也过滤它们 —— 两边隐藏的是同一批名字，所以「如何处理 `._`」在这条基准上**看不出差异**；而且基准是否通过还取决于 bsdtar 的默认行为（macOS 上默认开），**换机器/换版本就会飘**
  - 要独立校验过滤逻辑，就对「数」：参考侧给**完整**条目，与 tarprobe stderr 的计数对账。`real.unitypackage` 实测：
    ```
    tar --options '!mac-ext' -tf <pkg> | wc -l                 # 966  完整条目
    tar --options '!mac-ext' -tf <pkg> | grep -cE '(^|/)\._'    # 483  AppleDouble
    # 966 − 483 = 483 条真实条目；tarprobe 的「归一化后」= 482（483 再减掉根条目 `.`）
    ```
- **金标准文件已丢失**：`tar1/2.txt`、`out1/2.txt`、`refpn1/2.txt`、`stat1/2.txt` 原先与 spike 脚本同放在 `~/Documents/WorkingFolder/unitypackage-spike/`，那个目录现已不存在，本机也搜不到这些文件 —— 下次回归前请用上面的配方重新生成一份基线
- 局限：测的是**平行实现**，会与 `UnityPackageReader.swift` 漂移。更彻底的做法是抽核心 + 加 test target 直接测真实代码（未做）

## 测试样本清单（`testfiles/`）

> ⚠️ **这批样本尚未入库**（版权原因）。计划是后续自己构建一套无版权问题的样本再放进来；在那之前 `testfiles/` 只是本机目录，clone 下来的人拿不到，本节所有数字都要靠它才能复现。

| 样本 | 来源 | 条目 | `._` | pax 头 | 条目名 `./` 前缀 | magic |
| --- | --- | ---: | ---: | ---: | :---: | --- |
| `real.unitypackage` | macOS 导出 | 966 | 483 | 483 | 有 | POSIX ustar |
| `OCESAudio-0908.unitypackage` | macOS 导出 | 978 | 489 | 489 | 有 | POSIX ustar |
| `windows.unitypackage` | Windows 导出 | 331 | 0 | 0 | 无 | GNU oldgnu |
| `TMP Essential Resources.unitypackage` | Unity 官方 | 158 | 0 | 0 | 无 | POSIX ustar |
| `TMP Examples & Extras.unitypackage` | Unity 官方 | 547 | 0 | 0 | 无 | POSIX ustar |
| `fake.unitypackage` | 实为 WAV 改名（RIFF） | — | — | — | — | 非 tar.gz |
| `empty.unitypackage` | 0 字节空文件 | — | — | — | — | 空 |

- 条目数按 `python3 tarfile.getnames()` / `tar --options '!mac-ext'` 计 —— **不是**默认 `tar tzf`（后者少 483 条，见「参照工具陷阱」）
- `real` 与 `windows` 是**同一工程的两次导出**（87 vs 130 个资产，83 个 GUID 重合），但路径已重组（Windows 版多一层 `Sound/`）→ 适合做"同工程跨平台"对照
- `real` 与 `OCESAudio-0908`（130 / 132 个 guid，各 95 个 `asset`）结构相近，适合交叉验证解析器
- `.DS_Store`：两个 Mac 包各有 1 个，藏在 `pathname` **内容**里（`Assets/Plugins/Lofelt/iOS/LofeltHaptics.framework/.DS_Store`）；条目名里看不到，只能在 `pathname` 里查
