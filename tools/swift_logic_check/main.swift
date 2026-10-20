//
//  test_main.swift — Linux 数值验证（不交付，仅开发验证）
//  验证：boneMatrix 公式 / track 插值 / 投影矩阵 / 视锥剔除 / 级联阴影
//

import Foundation
import simd

let outDir = URL(fileURLWithPath: "/tmp/swifttest")

// ---------- 1. boneMatrix vs numpy ----------
let nbones = 4
var tracks: [Float] = []
for b in 0..<nbones {
    let s = Float(b + 1)
    let q = simd_normalize(simd_float3(0.1 * s, 0.2 * s, -0.15 * s))
    tracks += [q.x, q.y, q.z, 1.0, 0.5 * s, -0.3 * s, 1.2 * s, 1 + 0.1 * s, 1, 1]
}
let arm: [Float] = [
    0.9, 0.1, -0.2, 3.0,
    0.05, 0.95, 0.15, 2.0,
    0.2, -0.1, 0.97, -4.0,
    0, 0, 0, 1
]
let aw = simd_float4x4(rowMajor: arm)

func rowMajorDump(_ m: simd_float4x4) -> [Float] {
    (0..<4).flatMap { r in (0..<4).map { c in m[c][r] } }
}

var boneOut: [Float] = []
for b in 0..<nbones {
    let track = Array(tracks[b * 10..<(b + 1) * 10])
    let m = boneMatrix(q: simd_quatf(track: track),
                       t: simd_float3(track[4], track[5], track[6]),
                       s: simd_float3(track[7], track[8], track[9]),
                       armatureWorld: aw)
    boneOut += rowMajorDump(m)
}
var inputDump = ""
inputDump += "arm: " + arm.map { "\($0)" }.joined(separator: ",") + "\n"
for b in 0..<nbones {
    let track = Array(tracks[b * 10..<(b + 1) * 10])
    inputDump += "track: " + track.map { "\($0)" }.joined(separator: ",") + "\n"
}
try? inputDump.write(to: outDir.appendingPathComponent("bone_input.txt"), atomically: true, encoding: .utf8)
try? boneOut.map { "\($0)" }.joined(separator: "\n").write(to: outDir.appendingPathComponent("bone_swift.txt"), atomically: true, encoding: .utf8)

// ---------- 2. track 插值（slerp）----------
let ta: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 1, 1]
let tb: [Float] = [0.7071068, 0, 0, 0.7071068, 2, 0, 0, 2, 2, 2]
let (q, t, s) = interpolateTrack(a: ta, b: tb, frac: 0.5)
let interpOut = "q=\(q.vector.x),\(q.vector.y),\(q.vector.z),\(q.vector.w) t=\(t.x),\(t.y),\(t.z) s=\(s.x),\(s.y),\(s.z)"
try? interpOut.write(to: outDir.appendingPathComponent("interp_swift.txt"), atomically: true, encoding: .utf8)

// ---------- 3. 投影矩阵健全性 ----------
var projReport = ""
do {
    let proj = simd_float4x4.perspective(fovYDegrees: 60, aspect: 16.0 / 9.0, near: 0.1, far: 200)
    let inv = proj.inverse
    for zv in [0.1, 1.0, 50.0, 199.9] {
        // view 点 (0,0,-zv) -> clip
        let clip = proj * simd_float4(0, 0, Float(-zv), 1)
        let ndc = clip.z / clip.w
        // 反投影回 view
        let w = inv * simd_float4(0, 0, ndc, 1)
        projReport += "zv=\(zv) ndcZ=\(ndc) back=\(w.z / w.w)\n"
    }
}
do {
    let ortho = simd_float4x4.ortho(left: -5, right: 5, bottom: -5, top: 5, near: 0.01, far: 50)
    for zv in [-0.01, -25.0, -50.0] {
        let clip = ortho * simd_float4(1, 1, Float(zv), 1)
        projReport += "ortho zv=\(zv) ndcZ=\(clip.z / clip.w)\n"
    }
}
try? projReport.write(to: outDir.appendingPathComponent("proj_swift.txt"), atomically: true, encoding: .utf8)

// ---------- 4. 视锥剔除 ----------
var frustReport = ""
do {
    let view = simd_float4x4.lookAt(eye: simd_float3(0, 5, 10), center: simd_float3(0, 0, 0), up: simd_float3(0, 1, 0))
    let proj = simd_float4x4.perspective(fovYDegrees: 60, aspect: 16.0 / 9.0, near: 0.1, far: 200)
    let f = Frustum(viewProj: proj * view)
    let cases: [(String, simd_float3, simd_float3)] = [
        ("front-center", simd_float3(-1, -1, -1), simd_float3(1, 1, 1)),
        ("behind-camera", simd_float3(-1, -1, 11), simd_float3(1, 1, 12)),
        ("far-away", simd_float3(500, 500, -500), simd_float3(600, 600, -490)),
        ("far-plane-inside", simd_float3(-1, -1, -150), simd_float3(1, 1, -140)),
        ("off-fov-edge", simd_float3(80, -1, -10), simd_float3(90, 1, -5)),
        ("straddling-near", simd_float3(-1, -1, -0.05), simd_float3(1, 1, 0.05)),
    ]
    for (name, lo, hi) in cases {
        frustReport += "\(name): \(f.intersects(min: lo, max: hi))\n"
    }
}
try? frustReport.write(to: outDir.appendingPathComponent("frustum_swift.txt"), atomically: true, encoding: .utf8)

// ---------- 5. 级联阴影矩阵 ----------
var csmReport = ""
do {
    let view = simd_float4x4.lookAt(eye: simd_float3(0, 8, 14), center: simd_float3(0, 0, 0), up: simd_float3(0, 1, 0))
    let proj = simd_float4x4.perspective(fovYDegrees: 55, aspect: 16.0 / 9.0, near: 0.1, far: 200)
    let sun = simd_normalize(simd_float3(0.37, 0.83, 0.42))
    let total: Float = min(34.0, 200 * 0.95)
    let splits = simd_float3(total * 0.18, total * 0.45, total)
    let casc = cascadeMatrices(view: view, proj: proj, sunDir: sun, splits: splits, near: 0.1)
    for (i, c) in casc.enumerated() {
        let m = c.proj * c.view
        // 原点 (0,0,0) 应落在 light clip 范围内（xy ∈ [-1,1], z ∈ [0,1]）
        let clip = m * simd_float4(0, 0, 0, 1)
        let ndc = simd_float3(clip.x, clip.y, clip.z) / clip.w
        csmReport += "cascade\(i): ndc(0,0,0)=\(ndc.x),\(ndc.y),\(ndc.z)\n"
    }
}
try? csmReport.write(to: outDir.appendingPathComponent("csm_swift.txt"), atomically: true, encoding: .utf8)

// ---------- 6. VisibilityBitmap ----------
do {
    // 2 帧 × 70 组 -> 每帧 2 个 uint64
    var data = Data()
    // 帧0：group 0, 63, 64 可见；帧1：全不可见除 group 1
    var f0 = (UInt64(1) << 0) | (UInt64(1) << 63) | (UInt64(1) << 64)  // 注意 64 在第二个 word
    var f1 = UInt64(1) << 1
    withUnsafeBytes(of: &f0) { data.append(contentsOf: $0) }
    // 第二个 word（group 64-69）
    var f0b = UInt64(1) << 0
    withUnsafeBytes(of: &f0b) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: &f1) { data.append(contentsOf: $0) }
    var f1b = UInt64(0)
    withUnsafeBytes(of: &f1b) { data.append(contentsOf: $0) }
    if let vb = VisibilityBitmap(data: data, groups: 70, frames: 2) {
        let r = "f0g0=\(vb.isVisible(frame: 0, group: 0)) f0g63=\(vb.isVisible(frame: 0, group: 63)) "
              + "f0g64=\(vb.isVisible(frame: 0, group: 64)) f0g1=\(vb.isVisible(frame: 0, group: 1)) "
              + "f1g1=\(vb.isVisible(frame: 1, group: 1)) f1g0=\(vb.isVisible(frame: 1, group: 0))"
        try? r.write(to: outDir.appendingPathComponent("vis_swift.txt"), atomically: true, encoding: .utf8)
    }
}

// ---------- 7. RenderSettings 抽帧 ----------
do {
    var s = RenderSettings()
    s.outputFPS = 30
    s.sourceStart = 0
    s.sourceEnd = 3729     // 3730 帧
    let n = s.outputFrameCount(sourceFPS: 60)
    let f0 = s.sourceFrame(outputIndex: 0, sourceFPS: 60)
    let fLast = s.sourceFrame(outputIndex: n - 1, sourceFPS: 60)
    let fMid = s.sourceFrame(outputIndex: 100, sourceFPS: 60)
    let r = "count=\(n) f0=\(f0) f100=\(fMid) fLast=\(fLast)"
    try? r.write(to: outDir.appendingPathComponent("settings_swift.txt"), atomically: true, encoding: .utf8)
}

print("ALL TESTS DONE")
