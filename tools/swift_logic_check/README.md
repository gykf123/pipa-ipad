# Swift 逻辑层数值验证（Linux）

在无 macOS/Xcode 的环境验证 `PipaRender/Render/` 中纯逻辑代码的正确性：
骨骼矩阵公式、track slerp 插值、透视/正交投影、视锥剔除、级联阴影、可见性位图、抽帧。

```bash
# 需要 Swift 5.9+（Linux）
swiftc -emit-module -emit-library -module-name simd simd_shim.swift -o libsimd.so

# Linux 无 ProcessInfo.ThermalState：生成 RenderSettings 测试副本（enum case -> Int，逻辑等价）
python3 - <<'PYEOF'
src = open('../../PipaRender/PipaRender/Render/RenderSettings.swift').read()
src = src.replace('mutating func update(thermalState: ProcessInfo.ThermalState, avgFrameMs: Double) {',
                  'mutating func update(thermalState: Int, avgFrameMs: Double) {')
for a, b in [('case .critical:', 'case 3:'), ('case .serious:', 'case 2:'),
             ('case .fair:', 'case 1:'), ('case .nominal:', 'case 0:'),
             ('@unknown default:', 'default:')]:
    src = src.replace(a, b)
open('RenderSettings_linux.swift', 'w').write(src)
PYEOF

swiftc -I. -L. -lsimd -o test_runner main.swift RenderSettings_linux.swift \
    ../../PipaRender/PipaRender/Render/RenderMath.swift \
    ../../PipaRender/PipaRender/Render/Skinner.swift \
    ../../PipaRender/PipaRender/Render/VisibilityBitmap.swift
LD_LIBRARY_PATH=. ./test_runner     # 生成 *_swift.txt
python3 compare.py                 # 与 numpy 独立复刻对比
```

`simd_shim.swift` 是 Linux 下的 simd 兼容层（仅测试用，交付代码直接用系统 simd）。
当前结果：**ALL PASS**（boneMatrix 3.5e-7 / slerp 3.8e-8 / 投影深度 0 与 1 精确 / 剔除 6/6）。

> 此验证曾抓到 `perspective`/`ortho` 平移项行放置错误的真 bug（已修复）。
