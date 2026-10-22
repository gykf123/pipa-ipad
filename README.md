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
│   ├── creeper_flower_scene5.v2.zip  苦力怕花园样例（22 组 / 120 帧，v2 变体转换而来）
│   └── steve_softrender.png  Steve 样例的软渲染抽查图（3 帧）
├── tools/
│   ├── pack_package.py       打包器（纯 Python + numpy，见文件头用法）
│   ├── convert_v1_to_v2.py   v1 -> v2 转换器（外部工具按 v1 设计导出时用）
│   ├── validate_package.py   包验证器（导入前自检：FAIL/WARN 分级报告）
│   ├── golden_check/         JIT 编码 golden-bytes 比对（clang 交叉汇编逐字节 diff）
│   ├── jit_encode_check/     JIT 编码结构断言（指令族统计 / 循环闭环 / literal）
│   ├── jit_exec_check/       JIT 内核真执行验证（macOS arm64 + allow-jit 签名）
│   └── swift_logic_check/    Linux 数值验证套件（simd 兼容层 + numpy 对比）
└── PipaRender/               iPad App 源码（XcodeGen 工程，**不编译交付**）
    ├── project.yml           xcodegen generate -> PipaRender.xcodeproj
    └── PipaRender/
        ├── App/              @main 入口
        ├── Model/            包格式 Codable 模型 + 包仓库
        ├── Services/         零依赖 ZIP 解压（系统 libz）
        ├── Render/           Metal 渲染管线（见下）
        ├── JIT/              骨骼蒙皮 JIT（软件汇编 + 探测降级，见下）
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

## 骨骼蒙皮 JIT

骨骼蒙皮是每顶点每帧的热点循环。App 内置一个**纯软件 ARM64 汇编器**（`JIT/JITAssembler.swift`，
无任何依赖），运行时生成蒙皮内核机器码：

```
每顶点：4 骨矩阵查表 -> 权重混合 4x4 -> 法线变换（去掉平移行）
```

**三级探测降级**（`JIT/JITAvailability.swift`，零自动崩溃风险）：

| 级 | 条件 | 行为 |
|---|---|---|
| 1 | `mmap(MAP_JIT)` 成功 + 探针（`mov w0,#42; ret`）返回 42 | 走 JIT 内核 |
| 2 | MAP_JIT 失败（普通签名安装 / 无调试器） | 全程 Swift 参考实现（逐顶点解释） |
| 3 | 用户在设置里手动关闭 / 上次探针崩溃 | 持久化标记，不再自动尝试 |

> iOS 只对持有 `com.apple.security.cs.allow-jit` entitlement 的 App 开放 JIT（普通分发/免费签名
> 不具备），因此**设备上默认走 Swift 参考实现**；JIT 内核的正确性在 CI 的 macOS 真执行步骤中验证
> （自签名 + allow-jit，`tools/jit_exec_check/` 生成骨骼输入、执行内核、numpy 对比数值）。

**编码可信度三级验证**（CI 全绿才算数）：

1. `jit_encode_check` — 结构断言：指令族统计（CSEL/FADD/FSUB/FMLA 掩码点数）、循环闭环、literal 布局
2. `golden_check` — 手写语义等价 `.s` → clang 交叉汇编 → 解析 ELF64 取 `.text` → 与汇编器输出**逐字节 diff**
   （当前 680 bytes / 170 条指令完全一致）
3. `jit_exec_check` — macOS arm64 上真执行内核，与 numpy 参考实现对比每个浮点分量

编码器踩过的坑（都有对应断言兜底）：A64 通用寄存器无 SMAX/SMIN（只能 `cmp + csel`）；
CSEL 的 opc 位必须是 `00`（`01/10/11` 分别是 CSINC/CSINV/CSNEG）；
VFP imm8 映射反常（`fmov #1.0` 的 imm8 是 `0x70` 而非直觉值）。

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

# 部分导出工具直接产 v2 变体（meshes.groups + index_base: group_local）也走同一转换器：
python3 tools/convert_v1_to_v2.py <v2变体.zip> -o <v2包.zip> --uv-clamp
```

v1 -> v2 自动处理：标量数组交错为每顶点分量连续 / indices 合并入 meshes.bin 并转组内局部索引 /
movers 重排为组主序 / bones 丢弃（movers 已含全部动画）/ 补 defaults+sun 等必选字段。
索引基准按源包 `indices.index_base` 分流：缺省为全局索引（减 vertex_offset），
显式 `group_local` 时原样透传；`--uv-clamp` 把越界 UV 夹到 [0,1]（sampler 为 repeat）。
MC Steve 样例即由 `steve_walk_spin` v1 包转换而来；苦力怕花园样例由 v2 变体转换而来
（`sample/` 内有转换结果与软渲染抽查图）。

> v2 变体的已知局限：该变体的部件顶点为「关节锚定的归一化盒子」，包内只有 `pivot`
> 而无部件尺寸/锚点语义（同名为「腿」的部件 local 范围都不一致），转换器无法唯一
> 恢复装配，角色部件会按 pivot 平移后叠合（见 `sample/creeper_softrender.png` 的
> 竖直柱效果）；花（stem/petal）不受影响。需要正确体型时请用带完整尺寸信息的
> v1 包或 pack_package.py 重新打包。

## 已知限制

- `MAX_BONES = 16`（单角色骨骼上限）；`MAX_LIGHTS = 16`（点/面光上限）
- 面光 AREA normal 为 0 时不照明（忠实桌面端 shader 行为）
- 碎块（debris）解析弹道，最多 3 事件 × 30 块同时存活
- iOS 15+；质量分档 + 热控降档针对 A10 设计，30% 占用档为过热保险档
- 逻辑层数值已用 numpy 独立复刻交叉验证（见 `tools/swift_logic_check/`）
- 蒙皮 JIT 需要 allow-jit entitlement，普通签名安装的设备上自动走 Swift 参考实现（功能等价，慢一档）
