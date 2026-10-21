# PipaRender 包格式规范（pipapkg v2）

> 目标：**任何设备**（PC/Mac/服务器）把渲染任务压成一个标准 ZIP，iPad 应用导入后即可渲染。
> 设计原则：JSON 清单 + 标准二进制块 + PNG 贴图，全部可用 Python/Blender/C++ 生成，不依赖任何专有工具。
> v2 变更：全部数据由打包器烤入 **GL 基准（Y 向上）**；新增 camera_meta / debris / ao 块；
> bones 改为 q4t3s3（App 端现算矩阵并插值）；defaults 补齐全部渲染参数。
> 参考实现 `tools/pack_package.py`（纯 Python + numpy）。

## 1. ZIP 结构

```
<任务名>.pipapkg.zip          （普通 ZIP，扩展名仅作标识）
├── package.json              唯一清单（UTF-8，见 §3）
├── meshes.bin                全部网格顶点数据（静态场景 + 角色部件，SoA 拼接，GL 基准）
├── movers.bin                动态组每帧模型矩阵（多组拼接的扁平数组，见 §4）
├── bones.bin                 骨骼蒙皮 track [frames][bones][10] f4（q4+t3+s3，App 现算矩阵）
├── camera.bin                每帧视图矩阵 [frames][16] f4（world→view，GL 基准）
├── camera_meta.bin           每帧 (fov_deg, near, far, 0) [frames][4] f4
├── particles.bin             粒子系统（位置/自发光/速度/尺寸/帧区间，GL 基准）
├── visibility.bin            每帧每网格可见性位图（可选，见 §6）
├── debris.bin                墙板撞坏碎块参数（可选，见 §7）
├── ao.bin                    SSAO kernel(64×3) + noise(4×4×4) f4
├── textures/tex_000.png      PNG 贴图（任意尺寸，建议 ≤1024）
├── skins/char1.png           角色皮肤（64×64 MC 标准布局，可选）
└── audio.mp3                 成品 BGM（可选，m4a/aac/wav 亦可）
```

所有二进制块均为**小端序**，偏移量一律用**字节**。

## 2. 二进制数据类型约定

| dtype | 含义 | 字节数 |
|---|---|---|
| `f4` | float32 | 4 |
| `u4` | uint32 | 4 |

## 3. package.json 字段

```jsonc
{
  "format": "pipapkg",
  "version": 2,
  "name": "任务名",
  "fps": 60,                        // 源帧率
  "frame_start": 1,                 // 源帧起（含）
  "frame_end": 3730,                // 源帧止（含）
  "resolution": [1980, 1080],       // 源分辨率（输出按此比例）
  "shutter": 0.398,                 // 快门时间（秒）；粒子拖尾 half = vel * shutter * 0.5
  "world": { "background": [0.05,0.05,0.05] },
  "defaults": {                     // 渲染默认值（App 可改），见 §8 全表
    "exposure": 1.0, "gamma": 2.2, "tonemap": "filmic",
    "bloom": true, "bloom_threshold": 1.05, "bloom_strength": 0.35,
    "glare": true, "glare_threshold": 2.9, "glare_strength": 0.533,
    "glare_size": 1.083, "glare_smoothness": 0.1,
    "shadow": true, "shadow_samples": 16, "shadow_softness": 1.8, "shadow_distance": 34.0,
    "ao": true, "ao_samples": 24, "ao_intensity": 1.15, "ao_radius": 0.55,
    "ssr": false,
    "ambient_intensity": 3.4,
    "light_color": [1.0,0.96,0.9],
    "sky_color": [0.62,0.64,0.68], "ground_color": [0.4,0.41,0.44],
    "spec_strength": 0.55, "roughness": 0.45,
    "point_scale": 2.0, "point_soft": 0.8,
    "particle_scale": 1.0, "particle_streak": 1.0, "particle_width": 1.8,
    "debris": { "count": 30, "life": 1.25, "gravity": -17.0, "jump": 2.0, "shade": 0.65 }
  },
  "sun": {                          // 平行光（主光，GL 空间单位向量）
    "dir": [0.37, 0.83, 0.42],
    "color": [1.0, 0.96, 0.9], "intensity": 3.4,
    "shadow_softness": 1.8, "shadow_samples": 16
  },
  "lights": [                       // 点光/面光（已 GL 化，energy<=0 已过滤）
    { "type": "POINT", "energy": 14.2, "color": [1,0.036,0], "pos": [-2.56,7.57,-14.98] },
    { "type": "AREA",  "energy": 165.5, "color": [0.33,0.67,1.0],
      "pos": [4.77,6.44,-16.05], "normal": [0,0,0] }
  ],
  "camera": {
    "buffer": "camera.bin", "meta_buffer": "camera_meta.bin",
    "frames": 3730, "fov_unit": "degrees"
  },
  "groups": [                       // 静态场景网格（animated=true 的带 mat）
    {
      "name": "grp_000",
      "texture": "textures/tex_000.png",   // null = 无贴图
      "color": [0.8,0.8,0.8,1.0],
      "emission": [0,0,0],           // 自发光（HDR，>1 有效）
      "alpha_cut": true,             // 镂空表面（树叶等）
      "animated": false,             // true = 有逐帧矩阵（movers.bin）
      "bounds": { "min": [...], "max": [...] },   // GL 世界空间 AABB（剔除用）
      "verts": 5296, "indices": 7944,
      "buf": {
        "pos": { "offset": 0,      "count": 15888, "dtype": "f4" },   // ×3
        "nrm": { "offset": 63552,  "count": 15888, "dtype": "f4" },   // ×3
        "uv":  { "offset": 127104, "count": 10592, "dtype": "f4" },   // ×2
        "idx": { "offset": 169472, "count": 7944,  "dtype": "u4" }    // 三角形列表
      },
      "mat": { "file": "movers.bin", "offset": 0, "frames": 3730, "dtype": "f4" }   // offset 单位：字节
    }
  ],
  "characters": [
    {
      "name": "char1",
      "skin": "skins/char1.png",     // 可选；null = 用部件自带 UV
      "bones": ["Hip","Leg_Up.L", ...],
      "bone_count": 10,
      "armature_world": [...16...],  // Blender 空间 4×4 行主序（见 §5 公式）
      "bone_buffer": { "file": "bones.bin", "offset": 1492000, "frames": 3730, "bones": 10,
                       "dtype": "f4", "layout": "frame-major-q4t3s3" },
      "parts": [                     // 部件网格（蒙皮顶点）
        {
          "name": "p_char1_00", "alpha_cut": false,
          "bounds": { "min": [...], "max": [...] },   // GL 静置空间 AABB
          "verts": 454, "indices": 2112,
          "buf": {
            "pos": {...}, "nrm": {...}, "uv": {...}, "idx": {...},
            "bi": { "count": 1816 },    // 4 个骨骼索引/顶点（f4）
            "bw": { "count": 1816 }     // 4 个骨骼权重/顶点（f4）
          }
        }
      ]
    }
  ],
  "particles": {
    "buffer": "particles.bin",
    "count": 113676,
    "pos":  { "offset": 0,         "count": 341028 },  // ×3 世界坐标
    "em":   { "offset": 4410816,   "count": 341028 },  // ×3 HDR 自发光
    "vel":  { "offset": 8821632,   "count": 341028 },  // ×3 世界速度（拖尾方向）
    "size": { "offset": 13232448,  "count": 113676 },  // ×1 世界半径
    "off":  { "offset": 13685504,  "count": 3731, "dtype": "u4" }  // 每帧粒子区间 [first,last]
  },
  "visibility": {                   // 可选：打包时预计算的每帧可见性（§6）
    "buffer": "visibility.bin",
    "frames": 3730, "groups": 57,
    "layout": "frame-major-bitmask"  // 每帧 ceil(groups/64) 个 uint64
  },
  "debris": {                       // 可选：墙板撞坏碎块（§7）
    "buffer": "debris.bin",
    "events": [ { "frame": 574.0, "group": 12, "group_name": "mov_025",
                  "offset": 0, "count": 30, "floor": 4.996 } ]
  },
  "ao": { "buffer": "ao.bin", "kernel_count": 64, "noise_size": 4 },
  "audio": "audio.mp3"
}
```

## 4. 坐标与矩阵约定

- 世界坐标：Y 向上，右手系，单位米（**打包器已转换**，App 直接使用）。
- `camera.bin`：每帧 16 个 f4 行主序 4×4，**world→view 视图矩阵**。
  桌面端语义：`view = inv(BASIS @ m_cam2world_blender)`。
- `camera_meta.bin`：每帧 4 个 f4 = `(fov_deg, near, far, 0)`。
  桌面端语义：`fov = degrees(angle_y)`，`near = max(clip[0], 0.02)`，`far = min(max(clip[1], near+1), 600)`。
  投影矩阵由 App 生成（竖直 FOV，宽高比 = 输出宽/高）。
- `movers.bin`：动态组（`animated: true`）的每帧模型矩阵，**组主序扁平大数组**——所有动态组按 `groups[]` 数组顺序首尾拼接，每组一段连续的 `[frames][16]` 行主序矩阵（GL 基准）。组 g 第 f 帧的矩阵位于 float 偏移 `g.mat.offset / 4 + f * 16`（`mat.offset` 单位是**字节**，与 `bone_buffer.offset` 的 float 单位不同，勿混）。多组场景（N 个角色/物体）即为 N 段拼接，不存在"单矩阵"限制。
- 网格索引 `idx`：三角形列表，uint32。法线已随坐标转换。

## 5. 角色蒙皮（bones.bin = q4t3s3）

每帧每骨 10 个 f4：`q(4) + t(3) + s(3)`（四元数 xyzw、平移、缩放；Blender 空间）。
多角色可**共享同一个 bones.bin**（按 `bone_buffer.offset` 定位，单位 float；缺省按 characters 数组顺序累加，兼容旧包）。
App 按帧插值后计算最终蒙皮矩阵（数值验证误差 1e-7）：

```text
M = BASIS @ (armature_world @ (diag(s) @ R(q) + t)) @ BASIS_INV
BASIS     = [[1,0,0,0],[0,0,1,0],[0,-1,0,0],[0,0,0,1]]
BASIS_INV = inverse(BASIS)
```

插值规则（复刻桌面端）：`f = clamp(frame, frame_start, frame_end)`，
`a = floor(f) - frame_start`（夹到 [0, frames-1]），`b = min(a+1, frames-1)`，`frac = f - floor(f)`；
`frac <= 1e-6 或 a == b` 时取 a 帧；否则 **q 用 slerp、t/s 用 lerp**。
蒙皮：`v = Σ wᵢ · M(bone_indexᵢ) · v_rest`，法线用 `mat3(M)` 同权重混合。

## 6. 可见性预剔除（visibility.bin）

打包器对每帧做保守遮挡剔除，结果烤成位图：
- 布局：第 f 帧占 `ceil(groups/64)` 个 uint64（小端），第 g 位 = 1 表示该帧该 group **可能可见**。
- 算法（保守，绝不误删）：低分辨率深度 splat + 包围盒深度比较（遮挡物取最远深度、被测物取最近深度）。
- App 行为：位为 0 的 group 整帧跳过（不提交 draw）。角色部件不参与此剔除（App 做运行时视锥剔除兜底）。

## 7. 碎块系统（debris.bin）

墙板单帧瞬移超过 `jump` 视为"被撞坏"，喷出碎块。每个事件在 debris.bin 中连续存放：

```text
[0]   : bframe(f4)  group_index(f4)  floor_y(f4)  0(f4)     // 16 字节头
[16..]: count × ( p0(3) v0(3) axis(3) ang(1) size(1) ) f4  // 每块 11 floats
```

弹道（解析式，t = (frame - bframe) / fps，仅 t ∈ [0, life] 内存活）：

```text
pos = p0 + v0 * t + 0.5 * g * t²,  g = (0, gravity, 0)
pos.y = max(pos.y, floor)
model = T(pos) · R(axis, ang * t) · S(size * fade)
fade = 1 (t < 0.72·life) 否则 (1 - t/life) / 0.28
```

碎块用 App 内置单位立方体网格绘制，颜色 `(shade, shade, shade)`，贴图取事件所属 group 的贴图；
绘制顺序：场景组之后、角色之前；参与阴影与 G-buffer pass。

## 8. 粒子系统

- 粒子按帧连续存放：第 f 帧区间 = `[off[f], off[f+1])`（index = f - frame_start）。
- `pos` 世界坐标；`vel` 世界速度；`em` HDR 自发光颜色（可 >1）；`size` 世界半径。
- 渲染方式（App 固定）：每粒子画两次——
  1. **拖尾四边形**：沿 `vel * shutter * 0.5` 方向拉伸的屏幕空间四边形（6 顶点），
     像素半宽 = `particle_width`，长度 = `2 * |vel*shutter*0.5| * particle_streak`；
  2. **点精灵**：屏幕空间圆盘（6 顶点 quad），直径（像素）=
     `clamp(size * proj[1,1] * screen_h / view_z, 2, 96)`。
  两次均**加法混合、不写深度、不做深度测试**（贴原版 EEVEE 辉光行为）。

## 9. App 侧渲染参数（用户可选）

| 参数 | 选项 | 说明 |
|---|---|---|
| 成品帧率 | 24 / 30 / 60 | 源帧按比例抽帧（源帧索引 = frame_start + floor(i × src_fps / out_fps)，骨骼按 §5 插值） |
| 渲染最大占用 | 30% – 100% | 映射内部渲染分辨率倍率 + SSAO 采样数 + 阴影分辨率 + 泛光/辉光开关；热控自动降档 |
| 帧范围 | 起–止 | 默认全段 |
| 分段长度 | 默认 90 帧/段 | 断点续跑粒度 |

级联阴影（App 复刻桌面端）：splits = `[total·0.18, total·0.45, total]`，
`total = min(shadow_distance, far·0.95)`；每级用视锥截面求包围球，
`light_view = look_at(center - sun_dir·(r·2.5), center, up)`，
`light_proj = ortho(±r, ±r, 0.01, r·5)`（Metal 深度 [0,1] 变体）。
