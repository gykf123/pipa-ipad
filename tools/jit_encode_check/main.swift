//
//  jit_check.swift — JIT 内核编码验证（Linux x86_64 不解执行）
//
//  验证内容：
//   1. skinningCode() 结构断言（序言锚点 / 指令家族 / 循环闭环 / literal）
//   2. 确定性测试数据 + Swift 参考输出 dump（供 macOS CI 真执行对比）
//
//  编码权威性由 tools/golden_check/ 兜底：kernel_ref.s（clang 交叉汇编）与本
//  生成码逐字节对比——手写编码器的任何偏差在此暴露。
//
//  产物（当前目录）：jit_code.bin / jit_track.bin / jit_arm.bin / jit_expected.txt
//

import Foundation
import simd

// ---------- 1. 编码结构验证 ----------

let code = JITKernels.skinningCode()
var report = ""
var failed = false

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    report += "\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")\n"
    if !ok { failed = true }
}

check("长度合理（>600 字节）", code.count > 600, "\(code.count) 字节")
check("4 字节对齐", code.count % 4 == 0)

func u32at(_ i: Int) -> UInt32 {
    UInt32(code[i]) | (UInt32(code[i+1]) << 8) | (UInt32(code[i+2]) << 16) | (UInt32(code[i+3]) << 24)
}

// 序言锚点（前 8 条指令；clamp 用 cmp+csel——A64 无 GP 寄存器 smax/smin）
// 编码与 tools/golden_check/kernel_ref.s 的 clang 交叉汇编结果逐字节一致（golden-bytes 兜底）
let expectPrologue: [UInt32] = [
    0x1E24_0008,                       // fcvtas w8, s0
    0x4B04_0108,                       // sub  w8, w8, w4（减 frameStart，原硬编码 #4）
    0x7100_011F,                       // cmp  w8, #0
    0x1A88_B3E8,                       // csel w8, wzr, w8, lt
    0x5100_0449,                       // sub  w9, w2, #1
    0x6B09_011F,                       // cmp  w8, w9
    0x1A88_C128,                       // csel w8, w9, w8, gt
    0x5280_000A,                       // movz w10, #0
]
var prologueOK = true
for (i, want) in expectPrologue.enumerated() {
    if u32at(i * 4) != want { prologueOK = false }
}
check("序言锚点（fcvtas/sub/cmp/csel/movz）", prologueOK)

// 指令家族统计
var nMadd = 0, nFmla = 0, nFmul = 0, nFdiv = 0, nFadd = 0, nFsub = 0, nFmax = 0, nFneg = 0, nRet = 0, nLdr = 0, nStr = 0, nCsel = 0
var i = 0
while i + 4 <= code.count {
    let insn = u32at(i)
    switch insn & 0xFFC0_0000 {
    case 0x1B00_0000: nMadd += 1          // MADD W
    case 0x1F00_0000: nFmla += 1          // FMLA S
    default: break
    }
    switch insn & 0xFFFF_FFFF {
    case 0xD65F_03C0: nRet += 1
    default: break
    }
    if (insn & 0xFFE0_FC00) == 0x1E20_0800 { nFmul += 1 }   // FMUL S（opcode 00001）
    if (insn & 0xFFE0_FC00) == 0x1E20_1800 { nFdiv += 1 }   // FDIV S（opcode 00011）
    if (insn & 0xFFE0_FC00) == 0x1E20_2800 { nFadd += 1 }   // FADD S（opcode 00101）
    if (insn & 0xFFE0_FC00) == 0x1E20_3800 { nFsub += 1 }   // FSUB S（opcode 00111）
    if (insn & 0xFFE0_FC00) == 0x1E20_4800 { nFmax += 1 }   // FMAX S（opcode 01001）
    if (insn & 0xFFFF_FC00) == 0x1E21_4000 { nFneg += 1 }
    if (insn & 0xFFC0_0000) == 0xBD40_0000 { nLdr += 1 }
    if (insn & 0xFFC0_0000) == 0xBD00_0000 { nStr += 1 }
    if (insn & 0xFFF0_0C00) == 0x1A80_0000 { nCsel += 1 }   // CSEL W（opc bits[11:10]=00；01/10/11 为 CSINC/CSINV/CSNEG）
    i += 4
}
check("MADD ×1", nMadd == 1, "\(nMadd)")
check("FMLA ×27", nFmla == 27, "\(nFmla)")        // 3（q 归一化）+ 4 行 × 6（col3 改重 load，减 2 FMLA/行）
check("FMUL ×55", nFmul == 55, "\(nFmul)")        // 1(q)+9(中间)+9(R)+4 行×9（col3 改重 load 后乘 t，+2/行）
check("FDIV ×1", nFdiv == 1, "\(nFdiv)")
check("FADD ×18", nFadd == 18, "\(nFadd)")        // 6（R 矩阵）+ 4 行×3（col3 重 load 后 3 次 fadd）
check("FSUB ×6", nFsub == 6, "\(nFsub)")          // 3（R 对角）+ 3（R 非对角）
check("FMAX ×1", nFmax == 1, "\(nFmax)")
check("FNEG ×6", nFneg == 6, "\(nFneg)")          // 3 个 col2 + neg 行 3 个
check("CSEL ×2", nCsel == 2, "\(nCsel)")
check("RET ×1", nRet == 1, "\(nRet)")
check("LDR(浮点) ×38", nLdr == 38, "\(nLdr)")     // q/t/s 10 + 行内 16 + col3 重 load 3×4
check("STR(浮点) ×16", nStr == 16, "\(nStr)")

// literal 1e-20 位模式（f32 little-endian: 0x1E3CE508）
let litBytes: [UInt8] = [0x08, 0xE5, 0x3C, 0x1E]
check("literal 1e-20 在尾部", Array(code.suffix(4)) == litBytes)

// 循环闭环：尾部 5 条指令 = add x7/add w10/cmp/bcond/ret，随后 4 字节 literal
// loopTop = 序言 8 条 + literal LDR 1 条 = 36 字节
let tail = code.count - 24
check("循环尾 addImm(x7,#64)", u32at(tail) == 0x9101_00E7, String(format: "0x%08X", u32at(tail)))
check("循环尾 addImm32(w10,#1)", u32at(tail + 4) == 0x1100_054A, String(format: "0x%08X", u32at(tail + 4)))
check("循环尾 cmpReg(w10,w3)", u32at(tail + 8) == 0x6B03_015F, String(format: "0x%08X", u32at(tail + 8)))
let bcond = u32at(tail + 12)
check("循环尾 bcond.lt", (bcond & 0xFF00_001F) == 0x5400_000B, String(format: "0x%08X", bcond))
// imm19 = bits[23:5]，需符号扩展（回跳为负）
let imm19raw = Int((bcond >> 5) & 0x7FFFF)
let rel = (imm19raw >= 0x40000 ? imm19raw - 0x80000 : imm19raw) << 2
check("bcond 回指循环体", tail + 12 + rel == 36, "target=\(tail + 12 + rel)")
check("ret 在 literal 前", u32at(tail + 16) == 0xD65F_03C0)

try? report.write(toFile: "jit_report.txt", atomically: true, encoding: .utf8)
try? Data(code).write(to: URL(fileURLWithPath: "jit_code.bin"))

// ---------- 2. 确定性测试数据 + Swift 参考输出 ----------

let frames = 3, nbones = 4
var track: [Float] = []
for f in 0..<frames {
    for b in 0..<nbones {
        let s = Float(b + 1 + f)
        let q = simd_normalize(simd_float3(0.1 * s, 0.2 * s, -0.15 * s))
        // q4 + t3 + s3（Blender 空间，与 bone_input.txt 同构）
        track += [q.x, q.y, q.z, 1.0, 0.5 * s, -0.3 * s, 1.2 * s, 1 + 0.1 * s, 1, 1]
    }
}
let arm: [Float] = [
    0.9, 0.1, -0.2, 3.0,
    0.05, 0.95, 0.15, 2.0,
    0.2, -0.1, 0.97, -4.0,
    0, 0, 0, 1
]
let trackData = track.withUnsafeBufferPointer { Data(buffer: $0) }
try? trackData.write(to: URL(fileURLWithPath: "jit_track.bin"))
try? arm.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: "jit_arm.bin"))

var expected = ""
let aw = simd_float4x4(rowMajor: arm)
for fi in 0..<frames {
    let mats = Skinner.matrices(track: trackData, charOffsetFloats: 0,
                                frames: frames, boneCount: nbones,
                                frameStart: 0, frame: Float(fi), armatureWorld: aw)
    for m in mats {
        expected += (0..<4).flatMap { r in (0..<4).map { c in String(m[c][r]) } }.joined(separator: ",") + "\n"
    }
}
try? expected.write(to: URL(fileURLWithPath: "jit_expected.txt"), atomically: true, encoding: .utf8)

print(report)
print(failed ? "JIT ENCODE: FAIL" : "JIT ENCODE: ALL PASS")
exit(failed ? 2 : 0)
