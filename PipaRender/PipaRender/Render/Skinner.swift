//
//  Skinner.swift
//  PipaRender — 骨骼蒙皮矩阵求解（q4t3s3 -> simd_float4x4，公式数值验证误差 1e-7）
//

import Foundation
import simd

enum Skinner {
    /// 计算某角色在 float 源帧的每骨矩阵
    /// - parameter track: bones.bin 的 Data（mmap）
    /// - parameter charOffsetFloats: 该角色 track 起始 float 偏移（char1 段 + char2 段拼接）
    /// - parameter frameStart: 包 frame_start
    /// - parameter frame: 0 基 float 源帧号（可非整数，按 §5 插值）
    static func matrices(track: Data, charOffsetFloats: Int, frames: Int, boneCount: Int,
                         frameStart: Int, frame: Float,
                         armatureWorld: simd_float4x4) -> [simd_float4x4] {
        guard boneCount > 0, frames > 0 else { return [] }
        let f = max(Float(frameStart), min(frame, Float(frameStart + frames - 1)))
        let af = floor(f)
        var a = Int(af) - frameStart
        a = max(0, min(frames - 1, a))
        let b = min(a + 1, frames - 1)
        let frac = f - af
        let useA = frac <= 1e-6 || a == b

        let ptr = track.withUnsafeBytes { $0.bindMemory(to: Float.self).baseAddress!.advanced(by: charOffsetFloats) }
        func trackAt(_ frameIdx: Int, _ bone: Int) -> [Float] {
            let o = (frameIdx * boneCount + bone) * 10
            return Array(UnsafeBufferPointer(start: ptr.advanced(by: o), count: 10))
        }
        var out: [simd_float4x4] = []
        out.reserveCapacity(boneCount)
        for bone in 0..<boneCount {
            let ta = trackAt(a, bone)
            if useA {
                out.append(boneMatrix(q: simd_quatf(track: ta),
                                      t: simd_float3(ta[4], ta[5], ta[6]),
                                      s: simd_float3(ta[7], ta[8], ta[9]),
                                      armatureWorld: armatureWorld))
            } else {
                let tb = trackAt(b, bone)
                let (q, t, s) = interpolateTrack(a: ta, b: tb, frac: frac)
                out.append(boneMatrix(q: q, t: t, s: s, armatureWorld: armatureWorld))
            }
        }
        return out
    }
}
