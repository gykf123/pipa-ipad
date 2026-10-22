// simd_shim.swift — Linux 下的 simd 兼容层（仅用于本地数值验证，不交付）
// 提供 RenderMath.swift / Skinner.swift 所需 simd API 子集

import Foundation

public struct simd_float2 {
    public var x: Float, y: Float
    public init(_ x: Float, _ y: Float) { self.x = x; self.y = y }
    public init(repeating v: Float) { x = v; y = v }
}
public struct simd_float3 {
    public var x: Float, y: Float, z: Float
    public init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }
    public init(repeating v: Float) { x = v; y = v; z = v }
    public subscript(i: Int) -> Float {
        get { switch i { case 0: return x; case 1: return y; default: return z } }
        set { switch i { case 0: x = newValue; case 1: y = newValue; default: z = newValue } }
    }
}
public struct simd_float4 {
    public var x: Float, y: Float, z: Float, w: Float
    public init(_ x: Float, _ y: Float, _ z: Float, _ w: Float) { self.x = x; self.y = y; self.z = z; self.w = w }
    public init(repeating v: Float) { x = v; y = v; z = v; w = v }
    public init(_ v: simd_float3, _ w: Float) { x = v.x; y = v.y; z = v.z; self.w = w }
}

public func + (a: simd_float3, b: simd_float3) -> simd_float3 { simd_float3(a.x + b.x, a.y + b.y, a.z + b.z) }
public func - (a: simd_float3, b: simd_float3) -> simd_float3 { simd_float3(a.x - b.x, a.y - b.y, a.z - b.z) }
public func * (a: simd_float3, s: Float) -> simd_float3 { simd_float3(a.x * s, a.y * s, a.z * s) }
public func * (s: Float, a: simd_float3) -> simd_float3 { a * s }
public func / (a: simd_float3, s: Float) -> simd_float3 { simd_float3(a.x / s, a.y / s, a.z / s) }
public func + (a: simd_float4, b: simd_float4) -> simd_float4 { simd_float4(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w) }
public func - (a: simd_float4, b: simd_float4) -> simd_float4 { simd_float4(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w) }
public func * (a: simd_float4, s: Float) -> simd_float4 { simd_float4(a.x * s, a.y * s, a.z * s, a.w * s) }
public func min(_ a: simd_float3, _ b: simd_float3) -> simd_float3 {
    simd_float3(Swift.min(a.x, b.x), Swift.min(a.y, b.y), Swift.min(a.z, b.z))
}
public func max(_ a: simd_float3, _ b: simd_float3) -> simd_float3 {
    simd_float3(Swift.max(a.x, b.x), Swift.max(a.y, b.y), Swift.max(a.z, b.z))
}
public func dot(_ a: simd_float3, _ b: simd_float3) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
public func cross(_ a: simd_float3, _ b: simd_float3) -> simd_float3 {
    simd_float3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
public func length(_ v: simd_float3) -> Float { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }
public func normalize(_ v: simd_float3) -> simd_float3 { v / Swift.max(length(v), 1e-20) }
public func simd_normalize(_ v: simd_float3) -> simd_float3 { normalize(v) }
public func mix(_ a: simd_float3, _ b: simd_float3, _ t: simd_float3) -> simd_float3 {
    simd_float3(a.x + (b.x - a.x) * t.x, a.y + (b.y - a.y) * t.y, a.z + (b.z - a.z) * t.z)
}

// MARK: - 矩阵（列主序语义：m[col][row]）

public struct simd_float4x4 {
    var c0: simd_float4, c1: simd_float4, c2: simd_float4, c3: simd_float4

    public init() {
        c0 = simd_float4(1, 0, 0, 0); c1 = simd_float4(0, 1, 0, 0)
        c2 = simd_float4(0, 0, 1, 0); c3 = simd_float4(0, 0, 0, 1)
    }
    public init(rows: (simd_float4, simd_float4, simd_float4, simd_float4)) {
        c0 = simd_float4(rows.0.x, rows.1.x, rows.2.x, rows.3.x)
        c1 = simd_float4(rows.0.y, rows.1.y, rows.2.y, rows.3.y)
        c2 = simd_float4(rows.0.z, rows.1.z, rows.2.z, rows.3.z)
        c3 = simd_float4(rows.0.w, rows.1.w, rows.2.w, rows.3.w)
    }
    // Apple simd 的 rows: 接受数组（Linux shim 补同一签名，源码双平台通用）
    public init(rows: [simd_float4]) {
        self.init(rows: (rows[0], rows[1], rows[2], rows[3]))
    }
    public init(translation t: simd_float3) {
        self.init(rows: (simd_float4(1, 0, 0, t.x), simd_float4(0, 1, 0, t.y),
                         simd_float4(0, 0, 1, t.z), simd_float4(0, 0, 0, 1)))
    }
    public init(scale s: simd_float3) {
        self.init(rows: (simd_float4(s.x, 0, 0, 0), simd_float4(0, s.y, 0, 0),
                         simd_float4(0, 0, s.z, 0), simd_float4(0, 0, 0, 1)))
    }
    public init(_ q: simd_quatf) {
        let (x, y, z, w) = (q.vector.x, q.vector.y, q.vector.z, q.vector.w)
        let n = Swift.max(x * x + y * y + z * z + w * w, 1e-20)
        let s = 2.0 / n
        let (xx, yy, zz) = (x * x, y * y, z * z)
        let (xy, xz, yz) = (x * y, x * z, y * z)
        let (wx, wy, wz) = (w * x, w * y, w * z)
        self.init(rows: (
            simd_float4(1 - s * (yy + zz), s * (xy - wz), s * (xz + wy), 0),
            simd_float4(s * (xy + wz), 1 - s * (xx + zz), s * (yz - wx), 0),
            simd_float4(s * (xz - wy), s * (yz + wx), 1 - s * (xx + yy), 0),
            simd_float4(0, 0, 0, 1)
        ))
    }

    public subscript(column: Int) -> simd_float4 {
        switch column {
        case 0: return c0; case 1: return c1; case 2: return c2; default: return c3
        }
    }
    public subscript(column: Int, row: Int) -> Float { self[column][row] }

    /// 伴随矩阵求逆（4×4 通用）
    public var inverse: simd_float4x4 {
        func det3(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ e: Float, _ f: Float,
                  _ g: Float, _ h: Float, _ i: Float) -> Float {
            a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        }
        let m = self
        // 3×3 子式
        func sub(_ r0: Int, _ r1: Int, _ r2: Int, _ c0: Int, _ c1: Int, _ c2: Int) -> Float {
            m[c0, r0] * (m[c1, r1] * m[c2, r2] - m[c2, r1] * m[c1, r2])
          - m[c1, r0] * (m[c0, r1] * m[c2, r2] - m[c2, r1] * m[c0, r2])
          + m[c2, r0] * (m[c0, r1] * m[c1, r2] - m[c1, r1] * m[c0, r2])
        }
        let det = m[0, 0] * sub(1, 2, 3, 1, 2, 3) - m[1, 0] * sub(0, 2, 3, 0, 2, 3)
                + m[2, 0] * sub(0, 1, 3, 0, 1, 3) - m[3, 0] * sub(0, 1, 2, 0, 1, 2)
        guard abs(det) > 1e-30 else { return simd_float4x4() }
        var inv = simd_float4x4()
        func setCol(_ col: Int, _ v: simd_float4) {
            switch col {
            case 0: inv.c0 = v; case 1: inv.c1 = v; case 2: inv.c2 = v; default: inv.c3 = v
            }
        }
        let sign: (Int, Int) -> Float = { r, c in ((r + c) % 2 == 0) ? 1 : -1 }
        for col in 0..<4 {
            var v = simd_float4(0, 0, 0, 0)
            for row in 0..<4 {
                // A⁻¹[row][col] = (-1)^(row+col) * minor(col,row)/det
                let rows = (0..<4).filter { $0 != col }
                let cols = (0..<4).filter { $0 != row }
                let cof = sign(row, col) * sub(rows[0], rows[1], rows[2], cols[0], cols[1], cols[2])
                v[row] = cof
            }
            setCol(col, v * (1.0 / det))
        }
        return inv
    }
}

extension simd_float4 {
    public subscript(row: Int) -> Float {
        get {
            switch row { case 0: return x; case 1: return y; case 2: return z; default: return w }
        }
        set {
            switch row {
            case 0: x = newValue; case 1: y = newValue; case 2: z = newValue; default: w = newValue
            }
        }
    }
}

public func * (m: simd_float4x4, v: simd_float4) -> simd_float4 {
    simd_float4(
        m.c0.x * v.x + m.c1.x * v.y + m.c2.x * v.z + m.c3.x * v.w,
        m.c0.y * v.x + m.c1.y * v.y + m.c2.y * v.z + m.c3.y * v.w,
        m.c0.z * v.x + m.c1.z * v.y + m.c2.z * v.z + m.c3.z * v.w,
        m.c0.w * v.x + m.c1.w * v.y + m.c2.w * v.z + m.c3.w * v.w
    )
}
public func * (a: simd_float4x4, b: simd_float4x4) -> simd_float4x4 {
    var out = simd_float4x4()
    var cols: [simd_float4] = []
    for c in 0..<4 {
        cols.append(simd_float4(
            a.c0.x * b[c].x + a.c1.x * b[c].y + a.c2.x * b[c].z + a.c3.x * b[c].w,
            a.c0.y * b[c].x + a.c1.y * b[c].y + a.c2.y * b[c].z + a.c3.y * b[c].w,
            a.c0.z * b[c].x + a.c1.z * b[c].y + a.c2.z * b[c].z + a.c3.z * b[c].w,
            a.c0.w * b[c].x + a.c1.w * b[c].y + a.c2.w * b[c].z + a.c3.w * b[c].w
        ))
    }
    out.c0 = cols[0]; out.c1 = cols[1]; out.c2 = cols[2]; out.c3 = cols[3]
    return out
}

public let matrix_identity_float4x4 = simd_float4x4()

// MARK: - 四元数

public struct simd_quatf {
    public var vector: simd_float4     // xyzw
    public init(vector: simd_float4) { self.vector = vector }
    public init(angle: Float, axis: simd_float3) {
        let a = normalize(axis)
        let s = sinf(angle * 0.5)
        vector = simd_float4(a.x * s, a.y * s, a.z * s, cosf(angle * 0.5))
    }
}

/// 标准 slerp（与 simd 库语义一致：最短路径）
public func simd_slerp(_ q0: simd_quatf, _ q1: simd_quatf, _ t: Float) -> simd_quatf {
    var (a, b) = (q0.vector, q1.vector)
    var dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    if dot < 0 {
        b = simd_float4(-b.x, -b.y, -b.z, -b.w)
        dot = -dot
    }
    if dot > 0.9995 {
        // 近似线性
        var r = simd_float4(
            a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t,
            a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t)
        let l = Swift.max((r.x * r.x + r.y * r.y + r.z * r.z + r.w * r.w).squareRoot(), 1e-20)
        r = simd_float4(r.x / l, r.y / l, r.z / l, r.w / l)
        return simd_quatf(vector: r)
    }
    let theta = acosf(Swift.min(Swift.max(dot, -1), 1))
    let s0 = sinf((1 - t) * theta), s1 = sinf(t * theta)
    let st = sinf(theta)
    return simd_quatf(vector: simd_float4(
        (a.x * s0 + b.x * s1) / st, (a.y * s0 + b.y * s1) / st,
        (a.z * s0 + b.z * s1) / st, (a.w * s0 + b.w * s1) / st))
}
