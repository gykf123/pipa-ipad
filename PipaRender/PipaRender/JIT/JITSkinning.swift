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

    /// 与 Skinner.matrices 同输入，结果直接写入 dst（每骨 64 字节，**列主序**——
    /// Metal shader 直接按 float4x4 读；与降级路径 memcpy simd 对象的布局一致）
    static func matrices(track: Data, charOffsetFloats: Int, frames: Int, boneCount: Int,
                         frameStart: Int, frame: Float, armatureWorld: simd_float4x4,
                         into dst: UnsafeMutableRawPointer) {
        guard boneCount > 0, frames > 0 else { return }

        let useJIT = JITAvailability.isEnabled && frame == frame.rounded()
        if useJIT, let page = try? cachedPage() {
            let trackPtr = track.withUnsafeBytes { $0.bindMemory(to: Float.self).baseAddress! }
            // 内核按行主序行连续读 armatureWorld（stride 16B）；simd_float4x4 对象是
            // 列主序存储，直接传对象等于传转置矩阵——必须按行展开成 16 floats。
            // m[c][r] = 列 c 行 r；行主序第 r 行 = (m[0][r], m[1][r], m[2][r], m[3][r])。
            let aw = armatureWorld
            let awRowMajor: [Float] = [
                aw[0][0], aw[1][0], aw[2][0], aw[3][0],
                aw[0][1], aw[1][1], aw[2][1], aw[3][1],
                aw[0][2], aw[1][2], aw[2][2], aw[3][2],
                aw[0][3], aw[1][3], aw[2][3], aw[3][3]]
            // 内核输出也是行主序；shader 的 float4x4 要列主序——先落临时数组再转置搬运
            var tmp = [Float](repeating: 0, count: boneCount * 16)
            let ok = tmp.withUnsafeMutableBufferPointer { tmpBuf in
                guard let tmpPtr = tmpBuf.baseAddress else { return false }
                return awRowMajor.withUnsafeBufferPointer { awBuf -> Bool in
                    guard let awPtr = awBuf.baseAddress else { return false }
                    page.call { ptr in
                        // 内核 ABI 跳过 x5（见 JITKernels 头注）：INT 参数序列必须显式
                        // 占位一个 Int32，否则 armatureWorld 落 x5 / out 落 x6。
                        typealias Fn = @convention(c) (
                            UnsafeRawPointer, Int32, Int32, Int32, Int32, Float,
                            Int32,
                            UnsafeRawPointer, UnsafeMutablePointer<Float>) -> Void
                        let fn = unsafeBitCast(ptr, to: Fn.self)
                        fn(trackPtr, Int32(charOffsetFloats), Int32(frames), Int32(boneCount),
                           Int32(frameStart), frame,
                           0, awPtr, tmpPtr)
                    }
                    return true
                }
            }
            guard ok else { return }
            // 行主序 -> 列主序（renderMath 的 init(rowMajor:) 正好做这件事）
            for bi in 0..<boneCount {
                let m = simd_float4x4(rowMajor: Array(tmp[bi * 16..<(bi + 1) * 16]))
                _ = withUnsafePointer(to: m) { memcpy(dst.advanced(by: bi * 64), $0, 64) }
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
