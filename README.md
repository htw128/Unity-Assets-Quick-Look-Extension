# Unity Assets Quick Look Extension

让Quick Look支持预览以文本形式存储的Unity原生资产。

## 构建与安装

### 环境要求

- macOS 14.0 或更高
- Xcode 27 或更高

## 构建与安装

### 1. 构建

无需配置 Apple Developer Team ID，即可在本机编译项目。

```
xcodebuild \
  -project UnityAssetsQuickLook.xcodeproj \
  -scheme Extension \
  -configuration Release \
  -derivedDataPath /tmp/uaql-dd \
  build
```

构建成功后，生成的应用位于：

```
/tmp/uaql-dd/Build/Products/Release/UnityAssetsQuickLook.app
```

Quick Look 扩展位于应用包内部：

```
UnityAssetsQuickLook.app/Contents/PlugIns/Extension.appex
```

如果只需要确认代码能否编译，也可以跳过代码签名：

```
xcodebuild \
  -project UnityAssetsQuickLook.xcodeproj \
  -scheme Extension \
  -configuration Release \
  -derivedDataPath /tmp/uaql-dd \
  CODE_SIGNING_ALLOWED=NO \
  build
```

两种方式的区别：

- **默认构建**：保留 Xcode 的代码签名流程，适合后续安装和本机测试。
- **跳过签名**：仅关闭代码签名，用于快速验证编译是否通过。

项目的 `Config/Signing.xcconfig` 默认不指定 `DEVELOPMENT_TEAM`，因此无需 Apple Developer 账号即可进行本机构建。实际签名行为取决于 Xcode 的构建配置；如果需要确认签名类型，可使用 `codesign` 检查生成的应用。

### 2. 安装并启用扩展

1. 将 `UnityAssetsQuickLook.app` 复制到 `/Applications`。

2. 启动一次应用，使 macOS 能够发现并注册其中的 Quick Look 扩展。

3. 启用扩展。可以在终端执行：

   ```
   pluginkit -e use -i com.oces.UnityAssetsQuickLook.Extension
   ```

   也可以打开「系统设置 → 通用 → 登录项与扩展 → 快速查看」，找到并启用该扩展。不同 macOS 版本的界面名称可能略有差异。

4. 刷新 Quick Look 缓存：

   ```
   qlmanage -r
   qlmanage -r cache
   ```

### 3. 验证效果

在 Finder 中选中受支持的文件，例如 `.mat`、`.prefab` 或 `.unitypackage`，按空格键打开 Quick Look 预览。

### 4. 可选：配置个人代码签名

如果需要使用自己的 Apple Developer Team ID，可以通过本地配置文件完成设置，无需修改项目默认配置。

在 `Config/Signing.local.xcconfig` 中添加：

```
DEVELOPMENT_TEAM = ABCDE12345
```

将 `ABCDE12345` 替换为自己的 Team ID。

项目的 `Config/Signing.xcconfig` 通过以下语句引入该文件：

```
#include? "Signing.local.xcconfig"
```

其中，`#include?` 表示文件不存在时跳过导入。由于 `Signing.local.xcconfig` 已加入 `.gitignore`，个人签名配置不会随常规 Git 提交一起上传。

本地开发和测试通常不需要额外配置 Team ID。

## 卸载

1. 删除构建的宿主App。
2. 使用 `Tools/lskill.sh clean --yes`清除残留的LS注册项。

## Roadmap

-  [x] 支持 `.meta` 文件
-  [x] 支持 `.unitypackage` 文件
-  [x] 美化一下界面
-  [x] 支持更多文件类型
-  [x] 让别人 clone 下来后无需调整签名配置即可直接构建
-  [ ] 多语言
-  [ ] 给这些资产整一个不错的图标
-  [ ] 支持自定义配色方案
-  [ ] 支持辅助功能动态字号
-  [ ] 引入[UnityDataTools](https://github.com/Unity-Technologies/UnityDataTools)项目解析以二进制方式存储的文件
-  [ ] 支持非`UnityYAML`语法的文本



## 已支持的资产类型

| Extension           | Description                          | 描述                                    |
| ------------------- | ------------------------------------ | --------------------------------------- |
| .unitypackage       | Unity asset package                  | Unity 资源包                            |
| .anim               | Unity Animation Clip                 | Unity 动画片段                          |
| .asmdef             | Unity Assembly Definition            | Unity 程序集定义                        |
| .asset              | Unity native asset                   | Unity 原生资产                          |
| .brush              | Unity Terrain Brush                  | Unity 地形笔刷                          |
| .controller         | Unity Animator Controller            | Unity 动画控制器                        |
| .cubemap            | Unity Legacy Cubemap                 | Unity 旧版立方体贴图                    |
| .d3d12devicefilter  | D3D12 Device Filter                  | D3D12 设备过滤资源                      |
| .fontsettings       | Unity Custom Font                    | Unity 自定义字体                        |
| .giparams           | Unity global illumination parameters | Unity 全局光照参数                      |
| .guiskin            | Unity GUI skin                       | Unity GUI 皮肤                          |
| .lighting           | Unity lighting settings              | Unity 光照设置资产                      |
| .mask               | Unity Avatar Mask                    | Unity Avatar 遮罩                       |
| .mat                | Unity material asset                 | Unity 材质资产                          |
| .meta               | Unity meta file                      | Unity 元数据文件                        |
| .mixer              | Unity Audio Mixer                    | Unity 音频混音器                        |
| .overrideController | Unity Animator Override  Controller  | Unity 动画覆盖控制器                    |
| .physicMaterial     | Unity 3D physics material            | Unity 3D 物理材质                       |
| .physicsMaterial2D  | Unity 2D physics material            | Unity 2D 物理材质                       |
| .playable           | Unity Timeline asset                 | Unity Timeline 资产                     |
| .prefab             | Unity prefab asset                   | Unity 预制体资产                        |
| .preset             | Unity preset asset                   | Unity 预设资产                          |
| .renderTexture      | Unity render texture                 | Unity 渲染纹理                          |
| .shadervariants     | Unity Shader Variant collection      | Unity 着色器变体集合                    |
| .signal             | Unity Timeline Signal asset          | Unity Timeline 信号资产                 |
| .spriteatlas        | Unity Sprite atlas                   | Unity 精灵图集                          |
| .spriteLib          | Unity Sprite Library asset           | Unity Sprite Library 资产               |
| .terrainlayer       | Unity terrain layer                  | Unity 地形层                            |
| .unity              | Unity scene asset                    | Unity 场景资产                          |
| .vfx                | Unity Visual Effect Graph asset      | Unity Visual Effect Graph 资产          |
| .vfxblock           | Unity Visual Effect Graph Block      | Unity Visual Effect Graph Block 资产    |
| .vfxoperator        | Unity Visual Effect Graph Operator   | Unity Visual Effect Graph Operator 资产 |
| .vulkandevicefilter | Vulkan Device Filter                 | Vulkan 设备过滤资源                     |
| .wlt                | Unity workspace layout               | Unity 工作区布局                        |


## 计划支持的资产类型

| Extension     | Description                         | 描述                     |
| ------------- | ----------------------------------- | ------------------------ |
| .asmref       | Unity assembly definition reference | Unity 程序集定义引用     |
| .compute      | Unity compute shader                | Unity 计算着色器         |
| .inputactions | Unity Input Action asset            | Unity 输入操作资产       |
| .raytrace     | Unity Ray Tracing shader            | Unity 光线追踪着色器     |
| .shader       | Unity Shader                        | Unity 着色器             |
| .tss          | Unity theme style sheet             | Unity 主题样式表         |
| .urtshader    | Unity unified Ray Tracing shader    | Unity 统一光线追踪着色器 |
| .uss          | Unity style sheet                   | Unity 样式表             |
| .uxml         | Unity UI document                   | Unity UI 文档            |

## 版权声明

本项目使用 [MIT 许可证](LICENCE.md) 进行许可。

“Unity”及其他Unity商标是 Unity Technologies 或其附属机构在美国及其他地区的商标或注册商标。

macOS、Xcode、Finder 是 Apple Inc. 或在美国及其他地区的注册商标。

本项目中提及的所有其他商标、服务标志和商号均为其各自所有者的财产。