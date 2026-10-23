//
//  JITKernels.swift
//  PipaRender — 骨骼蒙皮内核的 ARM64 机器码生成
//
//  逐位复刻 Skinner.matrices（整数帧路径）+ boneMatrix 公式：
//    R(q) 归一化四元数矩阵 -> local = T(t)@S(s)@R -> M = BASIS @ armatureWorld @ local @ BASIS_INV
//  非整数帧（slerp 路径）不在本内核内，由调用方回退 Swift 实现（JITAvailability 决策）。
//
//  C ABI（Apple AArch64 调用约定）：
//    x0 = const float* track        bones.bin 基址
//    w1 = int32_t charOffsetFloats  角色段 float 偏移
//    w2 = int32_t frames
//    w3 = int32_t boneCount
//    w4 = int32_t frameStart
//    s0 = float frame               0 基 float 源帧号（内核按就近取整夹取）
//    x6 = const float* armatureWorld 16 floats 行主序
//    x7 = float* out                boneCount × 16 floats 行主序
//
//  ⚠ x5 有意跳过（寄存器分配留白）：调用方 @convention(c) 的 INT 参数序列必须显式
//  插一个占位 Int32，否则 armatureWorld 落 x5 / out 落 x6 → 内核读错地址（SIGBUS）。
//  参考 JITSkinning.swift 与 tools/jit_exec_check/main.swift 的写法。
//

import Foundation

public enum JITKernels {

    /// 生成骨骼蒙皮内核机器码（跨平台：只做编码，不执行）
    public static func skinningCode() -> [UInt8] {
        let a = JITAssembler()

        // ---- 寄存器分配（Apple AArch64，全 caller-saved，叶子函数无需保存）----
        // x0 track | x1 charOff | x2 frames | x3 bones | x4 frameStart | x6 armatureWorld | x7 out
        // w8 = a（帧索引）| w9 = frames-1 | w10 = bone index | w11 = 骨指针 | w12 = 临时
        // s0-s3 q | s4-s6 t | s7 ns | s8-s16 R 9 元素 | s17 = 1e-20 常量
        // s20-s22 s(xyz) | s24-s27 行内 f0/f1/f2/A3 | s28-s31 累加临时
        let R00: UInt32 = 8,  R01: UInt32 = 9,  R02: UInt32 = 10
        let R10: UInt32 = 11, R11: UInt32 = 12, R12: UInt32 = 13
        let R20: UInt32 = 14, R21: UInt32 = 15, R22: UInt32 = 16

        // ---- 序言：a = clamp(round(frame) - frameStart, 0, frames-1) ----
        // A64 无 GP 寄存器 smax/smin（仅 SIMD 向量形式），clamp 用 cmp+csel
        a.fcvtasW(8, 0)              // w8 = lround(frame)（整数帧无差）
        a.subReg(8, 8, 4)            // w8 -= frameStart（w4，运行时参数；原硬编码 #4 导致帧 1/2 全读成帧 0）
        a.cmpImm(8, 0)               // cmp w8, #0
        a.csel(8, 31, 8, .lt)        // w8 = (w8 < 0) ? 0 : w8      max(., 0)
        a.subImm32(9, 2, 1)          // w9 = frames - 1
        a.cmpReg(8, 9)               // cmp w8, w9
        a.csel(8, 9, 8, .gt)         // w8 = (w8 > w9) ? w9 : w8    min(., frames-1)
        a.movz32(10, 0)              // w10 = bone index = 0
        let lit1e20 = a.ldrFloatLiteral(17)   // s17 = 1e-20

        // ---- 每骨循环 ----
        a.defineLabel(1)

        // 骨 track 指针：x11 = x0 + (a*bones+bone)*40 + charOff*4
        a.madd(12, 8, 3, 10)         // w12 = a*bones + bone
        a.lsl64(12, 12, 5)           // ×32
        a.addRegLSL(12, 12, 12, 3)   // ×40
        a.addReg(11, 0, 12)
        a.addRegLSL(11, 11, 1, 2)    // + charOff*4

        // q/t/s 加载
        for i in 0..<4 { a.ldr32f(UInt32(i), 11, UInt32(i * 4)) }        // s0-s3
        for i in 0..<3 { a.ldr32f(UInt32(4 + i), 11, UInt32(16 + i * 4)) } // s4-s6
        for i in 0..<3 { a.ldr32f(UInt32(20 + i), 11, UInt32(28 + i * 4)) } // s20-s22

        // n = x²+y²+z²+w²; ns = 2 / max(n, 1e-20)
        a.fmul(7, 0, 0)
        a.fmla(7, 1, 1, 7)
        a.fmla(7, 2, 2, 7)
        a.fmla(7, 3, 3, 7)
        a.fmax(7, 7, 17)
        a.fmovImm(31, 0x00)          // s31 = 2.0（VFP imm8=0x00 经 capstone 实证为 #2.0）
        a.fdiv(7, 31, 7)             // ns

        // 中间量：s18-s29 = xx yy zz xy xz yz wx wy wz
        a.fmul(18, 0, 0); a.fmul(19, 1, 1); a.fmul(23, 2, 2)
        a.fmul(24, 0, 1); a.fmul(25, 0, 2); a.fmul(26, 1, 2)
        a.fmul(27, 3, 0); a.fmul(28, 3, 1); a.fmul(29, 3, 2)

        // R 9 元素
        a.fadd(30, 19, 23); a.fmul(30, 30, 7); a.fmovImm(31, 0x70); a.fsub(R00, 31, 30)  // r00
        a.fadd(30, 18, 23); a.fmul(30, 30, 7); a.fsub(R11, 31, 30)                      // r11
        a.fadd(30, 18, 19); a.fmul(30, 30, 7); a.fsub(R22, 31, 30)                      // r22
        a.fsub(30, 24, 29); a.fmul(R01, 30, 7)                                          // r01
        a.fadd(30, 24, 29); a.fmul(R10, 30, 7)                                          // r10
        a.fadd(30, 25, 28); a.fmul(R02, 30, 7)                                          // r02
        a.fsub(30, 25, 28); a.fmul(R20, 30, 7)                                          // r20
        a.fsub(30, 26, 27); a.fmul(R12, 30, 7)                                          // r12
        a.fadd(30, 26, 27); a.fmul(R21, 30, 7)                                          // r21

        // ---- 4 个 out 行：(outRow, X 行 rx, 取负) ----
        // out[r][c] 与 X[rx][c] 的映射（BASIS/BASIS_INV 列置换）：
        //   out 行0 <- X 行0（正）    out 行1 <- X 行2（正）
        //   out 行2 <- X 行1（负）    out 行3 <- X 行3（正）
        let rows: [(outRow: UInt32, rx: UInt32, neg: Bool)] = [
            (0, 0, false), (1, 2, false), (2, 1, true), (3, 3, false),
        ]
        for row in rows {
            let ab = row.rx * 16          // A 行字节偏移
            a.ldr32f(24, 6, ab + 0)       // A[rx][0]
            a.ldr32f(25, 6, ab + 4)       // A[rx][1]
            a.ldr32f(26, 6, ab + 8)       // A[rx][2]
            a.ldr32f(27, 6, ab + 12)      // A[rx][3]
            a.fmul(24, 24, 20)            // f0 = A0*sx
            a.fmul(25, 25, 21)            // f1 = A1*sy
            a.fmul(26, 26, 22)            // f2 = A2*sz
            let ob = row.outRow * 16
            // col0 = f0*r00 + f1*r10 + f2*r20
            a.fmul(28, 24, R00)
            a.fmla(28, 25, R10, 28)
            a.fmla(28, 26, R20, 28)
            if row.neg { a.fneg(28, 28) }
            a.str32f(28, 7, ob + 0)
            // col1 = f0*r02 + f1*r12 + f2*r22
            a.fmul(28, 24, R02)
            a.fmla(28, 25, R12, 28)
            a.fmla(28, 26, R22, 28)
            if row.neg { a.fneg(28, 28) }
            a.str32f(28, 7, ob + 4)
            // col2 = f0*r01 + f1*r11 + f2*r21（neg 行唯一不取负的列）
            a.fmul(28, 24, R01)
            a.fmla(28, 25, R11, 28)
            a.fmla(28, 26, R21, 28)
            if !row.neg { a.fneg(28, 28) }
            a.str32f(28, 7, ob + 8)
            // col3 = A[rx][0]*tx + A[rx][1]*ty + A[rx][2]*tz + A[rx][3]
            // 关键：平移不受缩放 s 影响（local = T(t)·S(s)·R(q)，T 在 S·R 左侧），
            // 旧实现用 f0=A[rx][0]*sx 乘 t 等于把平移错误缩放。
            a.ldr32f(28, 6, ab + 0)
            a.fmul(28, 28, 4)
            a.ldr32f(29, 6, ab + 4)
            a.fmul(29, 29, 5)
            a.ldr32f(30, 6, ab + 8)
            a.fmul(30, 30, 6)
            a.fadd(28, 28, 29)
            a.fadd(28, 28, 30)
            a.fadd(28, 28, 27)
            if row.neg { a.fneg(28, 28) }
            a.str32f(28, 7, ob + 12)
        }

        // 循环尾
        a.addImm(7, 7, 64)            // out += 64
        a.addImm32(10, 10, 1)         // bone++
        a.cmpReg(10, 3)               // cmp w10, w3（bones，运行时参数）
        a.bcond(.lt, 1)

        a.ret()
        a.placeLiteral(1e-20, for: lit1e20)
        return a.finalize()
    }
}
