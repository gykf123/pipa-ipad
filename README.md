# PipaRender — iPad 渲染器（pipapkg v2）

把桌面端（Blender/EEVEE 风格）渲染任务压成一个标准 ZIP，导入 iPad 后选参数渲染成品视频。
专为 **iPad 6（A10 Fusion / 2GB / 无风扇）** 设计：保守遮挡剔除 + 热控降档 + 分段断点续跑。

## 目录

```
pipa-ipad/
├── PackageFormat.md          ZIP 包格式规范（pipapkg v2）
├── sample/
│   ├── 琵琶曲.pipapkg.zip    样例包（57 组 / 2 角色 / 113676 粒子 / 3730 帧 / BGM）
│   ├── steve_walk_spin.v2.zip MC Steve 样例（7 部件 / 300 帧 / 30fps，v1 转换而来）
│   └── steve_softrender.png  Steve 样例的软渲染抽查图（3 帧）
├── tools/
│   ├── pack_package.py       打包器（纯 Python + numpy，见文件头用法）
│   ├── convert_v1_to_v2.py   v1 -> v2 转换器（外部工具按 v1 设计导出时用）
│   ├── validate_package.py   包验证器（导入前自检：FAIL/WARN 分级报告）
│   └── swift_logic_check/    Linux 数值验证套件（simd 兼容层 + numpy 对比）
└── PipaRender/               iPad App 源码（XcodeGen 工程，**不编译交付**）
    ├── project.yml           xcodegen generate -> PipaRender.xcodeproj
    └── PipaRender/
        ├── App/              @main 入口
        ├── Model/            包格式 Codable 模型 + 包仓库
        ├── Services/         零依赖 ZIP 解压（系统 libz）
        ├── Render/           Metal 渲染管线（见下）
        └── Views/            SwiftUI 界面
```

## 快速开始

```bash
cd PipaRender
brew install xcodegen   # 一次性
xcodegen generate       # 生成 .xcodeproj
open PipaRender.xcodeproj
```

Xcode 中选签名 Team（免费账号亦可），部署到 iPad 6（iOS 15+）。
App 内：右上角 `+` 导入 `.pipapkg.zip`（或隔空投送/文件 App 打开）→ 选参数 → 开始渲染。

> 无第三方 SPM 依赖。Metal shader 与 Swift 通过 `ShaderTypes.h` bridging header 共享结构体。

## 使用流程

1. **导入**：ZIP 落到 App 沙盒 `Documents/Packages/<uuid>/`，先校验 package.json 再全量解压。
2. **预览**：3D 预览可拖动旋转、双指缩放、拖动帧进度；可切回原相机轨迹。
3. **选参数**：
   - 成品帧率 24/30/60（源帧按比例抽帧，骨骼按浮点帧插值）
   - 渲染最大占用 30%–100%（映射内部分辨率 / SSAO 采样 / 阴影分辨率 / 泛光开关）
   - 帧范围、分段长度（默认 90 帧/段）、BGM 混合
4. **渲染**：分段编码 H.264，每段落盘 `seg_XXXX.mp4`；中断/杀进程后重启 App 可**续跑**。
5. **成品**：自动拼接段 + 混 BGM → `output.mp4`，一键存相册/分享。

## 防过热设计（iPad 6 A10）

| 手段 | 说明 |
|---|---|
| 遮挡剔除 | 打包期烘焙每帧组可见性位图（保守 splat + 深度比较，**绝不误删**）；位 0 的组整帧不提交 draw。样例 88.7% 的组·帧可跳过 |
| 视锥剔除 | 运行时 AABB vs 视锥（角色部件不参与，避免蒙皮包围盒误判） |
| 质量分档 | 占用率 -> 五档（0.4x–1.0x 内部分辨率 / 4–24 AO 采样 / 256–1024 阴影 / 泛光开关） |
| 热控降档 | 每段读 `thermalState` + 帧均耗时，连续降档（30% 封底） |
| 分段续跑 | 90 帧/段，段间天然冷却；`job.json` 持久化，杀进程不丢进度 |

## 渲染管线（逐 pass 复刻桌面端）

```
CSM 阴影 ×3（splits 0.18/0.45×distance，Metal 深度 [0,1]）
  -> G-buffer（albedo bgra8 / normal / viewpos / emit rgba16F，镂空 discard）
  -> SSAO（64 kernel + 4×4 噪声 TBN，可分离模糊）
  -> 光照（sun PCF 级联阴影 + GGX 高光 + 烘焙点/面光 + 半球环境）
  -> 粒子（拖尾 quad + 点精灵，加法混合无深度）
  -> 泛光（bright + 4 次 blur，半分辨率）
  -> 辉光（bright 2.9/0.1 + 8 次 blur，半径 1.083→8.664）
  -> tonemap（filmic，视频输出上下翻转）
```

坐标全部 **GL 基准 Y-up**（打包器烤入）；Metal NDC 深度 [0,1] 由矩阵约定处理；
骨骼 `M = BASIS @ (armature_world @ (diag(s)@R(q)+t)) @ BASIS_INV`（App 现算，误差 1e-7）。

## 打包新任务

```bash
python3 tools/pack_package.py --help     # 参数见文件头
# 输入：桌面端导出的 scene.bin / rig.bin / 轨迹 JSON / 贴图 PNG / audio.mp3
# 输出：<任务名>.pipapkg.zip（任何渲染任务转成此 ZIP 均可被本 App 渲染）
```

## 验证与转换（外部项目对接）

```bash
# 导入前自检：任何来源的包先过验证器
python3 tools/validate_package.py <包.zip> -v

# 外部工具按 v1 设计导出（meshes/indices 顶层段、8 标量数组）时，先转 v2：
python3 tools/convert_v1_to_v2.py <v1包.zip> -o <v2包.zip> --skin skins/char1.png
```

v1 -> v2 自动处理：标量数组交错为每顶点分量连续 / indices 合并入 meshes.bin 并转组内局部索引 /
movers 重排为组主序 / bones 丢弃（movers 已含全部动画）/ 补 defaults+sun 等必选字段。
MC Steve 样例即由 `steve_walk_spin` v1 包转换而来（`sample/` 内有转换结果与软渲染抽查图）。

## 已知限制

- `MAX_BONES = 16`（单角色骨骼上限）；`MAX_LIGHTS = 16`（点/面光上限）
- 面光 AREA normal 为 0 时不照明（忠实桌面端 shader 行为）
- 碎块（debris）解析弹道，最多 3 事件 × 30 块同时存活
- iOS 15+；质量分档 + 热控降档针对 A10 设计，30% 占用档为过热保险档
- 逻辑层数值已用 numpy 独立复刻交叉验证（见 `tools/swift_logic_check/`）
