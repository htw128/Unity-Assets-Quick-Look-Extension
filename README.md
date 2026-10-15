# Unity Assets Quick Look Extension

让Quick Look支持预览以文本形式存储的Unity原生资产。

## Roadmap

-  [x] 支持 `.meta` 文件
-  [x] 支持 `.unitypackage` 文件
-  [x] 美化一下界面
-  [x] 支持更多文件类型
-  [ ] 多语言
-  [ ] 给这些资产整一个不错的图标
-  [ ] 让别人 clone 下来后无需调整签名配置即可直接构建
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