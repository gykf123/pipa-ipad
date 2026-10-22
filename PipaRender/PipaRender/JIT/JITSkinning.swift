//
//  JITSkinning.swift
//  PipaRender — 骨骼矩阵求解的运行时入口（JIT 机器码 / Swift 参考实现自动二选一）
//
//  与 Skinner.matrices 完全同语义。判定规则：
//   - JIT 已启用（探针通过）+ frame 为整数 → 走 ARM64 内核
//   - 其余（非整数帧需 slerp / JIT 不可用 / 页面创建失败）→ 回退 Skinner.swift
//  生产路径 frame 恒为整数（抽帧 floor 后传入），热点全在 JIT 侧。
//

import Foundation
import simd

enum SkinKernel {

    /// 与 Skinner.matrices 同输入，结果直接写入 dst（每骨 64 字节行主序）
    static func matrices(track: Data, charOffsetFloats: Int, frames: Int, boneCount: Int,
                         frameStart: Int, frame: Float, armatureWorld: simd_float4x4,
                         into dst: UnsafeMutableRawPointer) {
        guard boneCount > 0, frames > 0 else { return }

        let useJIT = JITAvailability.isEnabled && frame == frame.rounded()
        if useJIT, let page = try? cachedPage() {
            let trackPtr = track.withUnsafeBytes { $0.bindMemory(to: Float.self).baseAddress! }
            var aw = armatureWorld
            page.call { ptr in
                typealias Fn = @convention(c) (
                    UnsafeRawPointer, Int32, Int32, Int32, Int32, Float,
                    UnsafeRawPointer, UnsafeRawPointer) -> Void
                let fn = unsafeBitCast(ptr, to: Fn.self)
                fn(trackPtr, Int32(charOffsetFloats), Int32(frames), Int32(boneCount),
                   Int32(frameStart), frame,
                   withUnsafePointer(to: &aw) { UnsafeRawPointer($0) }, dst)
            }
            return
        }

        // 降级：Swift 参考实现（含 slerp 非整数帧路径）
        let mats = Skinner.matrices(track: track, charOffsetFloats: charOffsetFloats,
                                    frames: frames, boneCount: boneCount,
                                    frameStart: frameStart, frame: frame,
                                    armatureWorld: armatureWorld)
        for (bi, m) in mats.enumerated() {
            _ = withUnsafePointer(to: m) { memcpy(dst.advanced(by: bi * 64), $0, 64) }
        }
    }

    // MARK: - 内核页面缓存（代码与 frames/bones 无关，全局生成一次）

    private static var page: JITPage?

    private static func cachedPage() throws -> JITPage {
        if let p = page { return p }
        let p = try JITEngine.makeExecutable(JITKernels.skinningCode())
        page = p
        return p
    }
}
