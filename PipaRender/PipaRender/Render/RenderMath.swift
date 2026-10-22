//
//  RenderMath.swift
//  PipaRender — 矩阵 / 四元数 / 级联阴影 / 视锥剔除（GL 基准 Y-up，Metal 深度 [0,1]）
//

import Foundation
import simd

// Blender(z-up) -> GL(y-up) 基准变换（与桌面端一致）
let BASIS: simd_float4x4 = simd_float4x4(rows: [
    simd_float4(1, 0, 0, 0),
    simd_float4(0, 0, 1, 0),
    simd_float4(0, -1, 0, 0),
    simd_float4(0, 0, 0, 1)
])

let BASIS_INV: simd_float4x4 = BASIS.inverse

extension simd_float4x4 {
    /// 由 numpy 行主序 16 floats 构造（乘法语义一致：行向量右乘）
    init(rowMajor a: [Float]) {
        self.init(rows: (
            simd_float4(a[0], a[1], a[2], a[3]),
            simd_float4(a[4], a[5], a[6], a[7]),
            simd_float4(a[8], a[9], a[10], a[11]),
            simd_float4(a[12], a[13], a[14], a[15])
        ))
    }

    /// Metal 深度 [0,1] 透视投影（竖直 FOV，单位：度）
    static func perspective(fovYDegrees: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = 1.0 / tanf(fovYDegrees * .pi / 360.0)
        let nf = near - far
        return simd_float4x4(rows: (
            simd_float4(f / aspect, 0, 0, 0),
            simd_float4(0, f, 0, 0),
            simd_float4(0, 0, far / nf, far * near / nf),
            simd_float4(0, 0, -1, 0)
        ))
    }

    /// Metal 深度 [0,1] 正交投影（view z ∈ [-far, -near] -> ndc z ∈ [1, 0]）
    static func ortho(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
        let fn = far - near
        return simd_float4x4(rows: (
            simd_float4(2 / (right - left), 0, 0, -(right + left) / (right - left)),
            simd_float4(0, 2 / (top - bottom), 0, -(top + bottom) / (top - bottom)),
            simd_float4(0, 0, -1 / fn, -near / fn),
            simd_float4(0, 0, 0, 1)
        ))
    }

    static func lookAt(eye: simd_float3, center: simd_float3, up: simd_float3) -> simd_float4x4 {
        let z = normalize(eye - center)
        var x = cross(up, z)
        if length(x) < 1e-6 { x = cross(simd_float3(0, 0, 1), z) }
        x = normalize(x)
        let y = cross(z, x)
        return simd_float4x4(rows: (
            simd_float4(x.x, x.y, x.z, -dot(x, eye)),
            simd_float4(y.x, y.y, y.z, -dot(y, eye)),
            simd_float4(z.x, z.y, z.z, -dot(z, eye)),
            simd_float4(0, 0, 0, 1)
        ))
    }
}

// MARK: - 骨骼

extension simd_quatf {
    init(track: [Float]) { self.init(vector: simd_float4(track[0], track[1], track[2], track[3])) }
}

/// q4t3s3 -> 蒙皮矩阵。
/// 公式：M = BASIS @ (armature_world @ (diag(s) @ R(q) + t)) @ BASIS_INV
/// 其中 diag(s)@R + t（4×4）= T(t) @ S(s) @ R(q)（T/S/R 均为 Blender 空间 4×4）。
func boneMatrix(q: simd_quatf, t: simd_float3, s: simd_float3, armatureWorld: simd_float4x4) -> simd_float4x4 {
    let r = simd_float4x4(q)
    let local = simd_float4x4(translation: t) * simd_float4x4(scale: s) * r
    return BASIS * armatureWorld * local * BASIS_INV
}

/// track 插值（复刻桌面端）：q 用 slerp，t/s 用 lerp
func interpolateTrack(a: [Float], b: [Float], frac: Float) -> (q: simd_quatf, t: simd_float3, s: simd_float3) {
    let q = simd_slerp(simd_quatf(track: a), simd_quatf(track: b), frac)
    let ta = simd_float3(a[4], a[5], a[6]), tb = simd_float3(b[4], b[5], b[6])
    let sa = simd_float3(a[7], a[8], a[9]), sb = simd_float3(b[7], b[8], b[9])
    return (q, mix(ta, tb, simd_float3(repeating: frac)), mix(sa, sb, simd_float3(repeating: frac)))
}

// MARK: - 级联阴影（复刻桌面端 _cascade_matrices）

/// splits 为各级 view 深度远界；near 为相机近面。返回每级 (world->light view, light view->clip)。
func cascadeMatrices(view: simd_float4x4, proj: simd_float4x4, sunDir: simd_float3,
                     splits: simd_float3, near: Float) -> [(view: simd_float4x4, proj: simd_float4x4)] {
    let invVP = (proj * view).inverse
    // 由 proj 反推 view 深度 zv 处的 NDC z：clip.z = a*(-zv) + b, clip.w = zv
    let a = proj[2][2], b = proj[3][2]
    func ndcZ(_ zv: Float) -> Float { (b - a * zv) / max(zv, 1e-5) }

    var out: [(view: simd_float4x4, proj: simd_float4x4)] = []
    var prev = near
    for i in 0..<3 {
        let far = max(splits[i], prev + 0.05)
        var lo = simd_float3(repeating: .greatestFiniteMagnitude)
        var hi = simd_float3(repeating: -.greatestFiniteMagnitude)
        for z in [prev, far] {
            let nz = ndcZ(z)
            for x in [Float(-1), Float(1)] {
                for y in [Float(-1), Float(1)] {
                    let w = invVP * simd_float4(x, y, nz, 1)
                    let p = simd_float3(w.x, w.y, w.z) / w.w
                    lo = min(lo, p); hi = max(hi, p)
                }
            }
        }
        let center = (lo + hi) * 0.5
        let r = max(length(hi - center) * 1.05, 0.5)
        let lv = simd_float4x4.lookAt(eye: center - sunDir * (r * 2.5), center: center, up: simd_float3(0, 1, 0))
        let lp = simd_float4x4.ortho(left: -r, right: r, bottom: -r, top: r, near: 0.01, far: r * 5)
        out.append((lv, lp))
        prev = far
    }
    return out
}

// MARK: - 视锥剔除

struct Frustum {
    /// 6 个平面（世界空间，法线朝内）：dot(n, p) + d >= 0 在内
    var planes: [simd_float4]

    init(viewProj: simd_float4x4) {
        let m = viewProj
        func row(_ i: Int) -> simd_float4 { simd_float4(m[0][i], m[1][i], m[2][i], m[3][i]) }
        let r0 = row(0), r1 = row(1), r2 = row(2), r3 = row(3)
        var p: [simd_float4] = []
        for combo in [(r3 + r0), (r3 - r0), (r3 + r1), (r3 - r1), (r3 + r2), (r3 - r2)] {
            let n = simd_float3(combo.x, combo.y, combo.z)
            let l = max(length(n), 1e-6)
            p.append(simd_float4(n / l, combo.w / l))
        }
        planes = p
    }

    /// 保守：AABB 完全在任一平面外才剔除
    func intersects(min lo: simd_float3, max hi: simd_float3) -> Bool {
        for p in planes {
            let n = simd_float3(p.x, p.y, p.z)
            let far = simd_float3(n.x >= 0 ? hi.x : lo.x,
                                  n.y >= 0 ? hi.y : lo.y,
                                  n.z >= 0 ? hi.z : lo.z)
            if dot(n, far) + p.w < 0 { return false }
        }
        return true
    }
}