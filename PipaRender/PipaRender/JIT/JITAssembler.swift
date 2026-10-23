//
//  JITAssembler.swift
//  PipaRender — ARM64 (A64) 机器码发射器
//
//  仅覆盖骨骼蒙皮内核所需指令子集（标量 f32 + 整数寻址 + 分支 + literal）。
//  纯字节数组操作、无平台依赖：Linux CI 可对编码结果做 golden-bytes 验证。
//  编码依据 ARMv8-A Architecture Reference Manual（A64 指令集）。
//

import Foundation

public final class JITAssembler {
    public private(set) var bytes: [UInt8] = []

    // label 回填：b / b.cond 的目标偏移在 emit 时未知
    private enum Fixup { case b, bcond(UInt32) }   // bcond 带 cond 字段
    private var fixups: [(at: Int, label: Int, kind: Fixup)] = []
    private var labelPos: [Int: Int] = [:]

    public init() {}

    // MARK: - 基础

    @discardableResult
    public func emit(_ insn: UInt32) -> Self {
        bytes.append(UInt8(insn & 0xFF))
        bytes.append(UInt8((insn >> 8) & 0xFF))
        bytes.append(UInt8((insn >> 16) & 0xFF))
        bytes.append(UInt8((insn >> 24) & 0xFF))
        return self
    }

    /// 当前 code offset（字节）
    public var offset: Int { bytes.count }

    public func defineLabel(_ label: Int) {
        labelPos[label] = bytes.count
    }

    /// 结束发射：回填所有未决分支，返回最终字节
    public func finalize() -> [UInt8] {
        for (at, label, kind) in fixups {
            guard let target = labelPos[label] else { continue }
            let rel = target - at      // 字节差（回跳为负）
            switch kind {
            case .b:
                let imm26 = UInt32(bitPattern: Int32(rel / 4)) & 0x03FF_FFFF
                patch(at, 0x1400_0000 | imm26)
            case .bcond(let cond):
                let imm19 = UInt32(bitPattern: Int32(rel / 4)) & 0x7FFFF
                patch(at, 0x5400_0000 | (imm19 << 5) | cond)
            }
        }
        fixups.removeAll()
        return bytes
    }

    private func patch(_ at: Int, _ insn: UInt32) {
        bytes[at] = UInt8(insn & 0xFF)
        bytes[at + 1] = UInt8((insn >> 8) & 0xFF)
        bytes[at + 2] = UInt8((insn >> 16) & 0xFF)
        bytes[at + 3] = UInt8((insn >> 24) & 0xFF)
    }

    // MARK: - 分支

    public func b(_ label: Int) { fixups.append((bytes.count, label, .b)); emit(0x1400_0000) }
    public func bcond(_ cond: Cond, _ label: Int) {
        fixups.append((bytes.count, label, .bcond(cond.rawValue))); emit(0x5400_0000 | cond.rawValue)
    }
    public func ret() { emit(0xD65F_03C0) }

    public enum Cond: UInt32 {
        case eq = 0, ne, cs, cc, mi, pl, vs, vc, hi, ls, ge, lt, gt, le, al
    }

    // MARK: - 整数

    public func addImm(_ rd: UInt32, _ rn: UInt32, _ imm: UInt32) {   // imm 缩放 ×4096 太大时勿用
        emit(0x9100_0000 | ((imm & 0xFFF) << 10) | (rn << 5) | rd)
    }
    public func addImm32(_ rd: UInt32, _ rn: UInt32, _ imm: UInt32) {
        emit(0x1100_0000 | ((imm & 0xFFF) << 10) | (rn << 5) | rd)
    }
    public func addReg(_ rd: UInt32, _ rn: UInt32, _ rm: UInt32) {    // 64 位，无移位
        emit(0x8B00_0000 | (rm << 16) | (rn << 5) | rd)
    }
    public func addRegLSL(_ rd: UInt32, _ rn: UInt32, _ rm: UInt32, _ sh: UInt32) {
        emit(0x8B00_0000 | (sh << 10) | (rm << 16) | (rn << 5) | rd)  // shift = LSL(#sh)
    }
    public func subImm(_ rd: UInt32, _ rn: UInt32, _ imm: UInt32) {
        emit(0xD100_0000 | ((imm & 0xFFF) << 10) | (rn << 5) | rd)
    }
    public func subImm32(_ rd: UInt32, _ rn: UInt32, _ imm: UInt32) {
        emit(0x5100_0000 | ((imm & 0xFFF) << 10) | (rn << 5) | rd)
    }
    /// SUB Wd, Wn, Wm（移位寄存器形式，用于运行时寄存器相减，如减去 frameStart）
    public func subReg(_ rd: UInt32, _ rn: UInt32, _ rm: UInt32) {
        emit(0x4B00_0000 | (rm << 16) | (rn << 5) | rd)
    }
    public func subsImm(_ rd: UInt32, _ rn: UInt32, _ imm: UInt32) {  // 32 位 SUBS（设标志）
        emit(0x7100_0000 | ((imm & 0xFFF) << 10) | (rn << 5) | rd)
    }
    public func cmpImm(_ rn: UInt32, _ imm: UInt32) { subsImm(31, rn, imm) }
    /// CMP Wn, Wm（SUBS 移位寄存器形式，Rd=31 作丢弃目标；扩展寄存器形式 0xEB00_001F 是 64 位且语义不同）
    public func cmpReg(_ rn: UInt32, _ rm: UInt32) { emit(0x6B00_001F | (rm << 16) | (rn << 5)) }
    /// CSEL Wd, Wn, Wm, cond：cond 为真取 Wn，否则取 Wm。
    /// 注意：A64 无 GP 寄存器 SMAX/SMIN/UMAX/UMIN（仅 SIMD 向量形式有此名），
    /// max/min/clamp 一律 cmp + csel 实现（LLVM 对 a>b?a:b 亦生成此序列）。
    /// 基址 0x1A80_0000：opc bits[11:10]=00 才是 CSEL；0x1A80_0C00 是 CSNEG（会对 Wm 取负）。
    public func csel(_ rd: UInt32, _ rn: UInt32, _ rm: UInt32, _ cond: Cond) {
        emit(0x1A80_0000 | (rm << 16) | (cond.rawValue << 12) | (rn << 5) | rd)
    }
    public func movz(_ rd: UInt32, _ imm16: UInt32, _ hw: UInt32 = 0) {
        emit(0xD280_0000 | (hw << 21) | ((imm16 & 0xFFFF) << 5) | rd)
    }
    public func movz32(_ rd: UInt32, _ imm16: UInt32, _ hw: UInt32 = 0) {
        emit(0x5280_0000 | (hw << 21) | ((imm16 & 0xFFFF) << 5) | rd)
    }
    public func movk(_ rd: UInt32, _ imm16: UInt32, _ hw: UInt32 = 0) {
        emit(0xF280_0000 | (hw << 21) | ((imm16 & 0xFFFF) << 5) | rd)
    }
    public func movReg(_ rd: UInt32, _ rm: UInt32) { emit(0xAA00_03E0 | (rm << 16) | rd) }  // MOV Rd, Rm (ORR)
    /// LSL Xd, Xn, #sh（汇编器以 ORR Xd, XZR, Xn, LSL #sh 生成）
    public func lsl64(_ rd: UInt32, _ rn: UInt32, _ sh: UInt32) {
        emit(0xAA00_0000 | ((sh & 0x3F) << 10) | (rn << 16) | (31 << 5) | rd)
    }
    public func madd(_ rd: UInt32, _ rn: UInt32, _ rm: UInt32, _ ra: UInt32) {
        emit(0x1B00_0000 | (rm << 16) | (ra << 10) | (rn << 5) | rd)
    }
    public func lsl32(_ rd: UInt32, _ rn: UInt32, _ sh: UInt32) {
        emit(0x5300_0000 | (sh << 10) | (rn << 5) | rd)   // UBFM 等价格式（32 位 LSL 立即数）
    }

    // MARK: - 加载/存储（无符号立即数偏移）

    public func ldr64(_ rt: UInt32, _ rn: UInt32, _ byteOff: UInt32) {
        precondition(byteOff % 8 == 0)
        emit(0xF940_0000 | (((byteOff / 8) & 0xFFF) << 10) | (rn << 5) | rt)
    }
    public func ldr32f(_ rt: UInt32, _ rn: UInt32, _ byteOff: UInt32) {
        precondition(byteOff % 4 == 0)
        emit(0xBD40_0000 | (((byteOff / 4) & 0xFFF) << 10) | (rn << 5) | rt)  // LDR S
    }
    public func str32f(_ rt: UInt32, _ rn: UInt32, _ byteOff: UInt32) {
        precondition(byteOff % 4 == 0)
        emit(0xBD00_0000 | (((byteOff / 4) & 0xFFF) << 10) | (rn << 5) | rt)  // STR S
    }
    /// LDR (literal) 32 位浮点：从代码池取常量。返回记录供回填。
    public func ldrFloatLiteral(_ rt: UInt32) -> (UInt32, Int) {
        let at = bytes.count
        emit(0x1C00_0000 | rt)    // LDR St, label（imm19 暂 0，回填）
        return (rt, at)
    }

    // MARK: - 浮点（标量 S）

    public func fmul(_ rd: UInt32, _ rn: UInt32, _ rm: UInt32) { emit(0x1E20_0800 | (rm << 16) | (rn << 5) | rd) }
    public func fdiv(_ rd: UInt32, _ rn: UInt32, _ rm: UInt32) { emit(0x1E20_1800 | (rm << 16) | (rn << 5) | rd) }
    public func fadd(_ rd: UInt32, _ rn: UInt32, _ rm: UInt32) { emit(0x1E20_2800 | (rm << 16) | (rn << 5) | rd) }
    public func fsub(_ rd: UInt32, _ rn: UInt32, _ rm: UInt32) { emit(0x1E20_3800 | (rm << 16) | (rn << 5) | rd) }
    public func fmla(_ rd: UInt32, _ rn: UInt32, _ rm: UInt32, _ ra: UInt32) {
        emit(0x1F00_0000 | (rm << 16) | (ra << 10) | (rn << 5) | rd)
    }
    public func fmax(_ rd: UInt32, _ rn: UInt32, _ rm: UInt32) { emit(0x1E20_4800 | (rm << 16) | (rn << 5) | rd) }
    public func fneg(_ rd: UInt32, _ rn: UInt32) { emit(0x1E21_4000 | (rn << 5) | rd) }
    public func fmovImm(_ rd: UInt32, _ imm8: UInt32) { emit(0x1E20_1000 | ((imm8 & 0xFF) << 13) | rd) }
    public func fmovToGpr(_ rd: UInt32, _ rn: UInt32) { emit(0x1E26_0000 | (rn << 5) | rd) }  // FMOV Wd, Sn
    public func fmovFromGpr(_ rd: UInt32, _ rn: UInt32) { emit(0x1E27_0000 | (rn << 5) | rd) }  // FMOV Sd, Wn
    public func fcvtasW(_ rd: UInt32, _ rn: UInt32) { emit(0x1E24_0000 | (rn << 5) | rd) }     // FCVTAS Wd, Sn（就近取整）
    public func frintm(_ rd: UInt32, _ rn: UInt32) { emit(0x1E21_5000 | (rn << 5) | rd) }      // FRINTM（floor）

    // MARK: - literal 池回填

    private var literalFixups: [(at: Int, value: UInt32)] = []

    /// 在代码尾部放置 4 字节 literal，并回填此前登记的 ldrFloatLiteral。
    /// 必须在所有指令发射完后调用；label 语义 = 当前 offset。
    public func placeLiteral(_ value: Float, for record: (UInt32, Int)) {
        literalFixups.append((record.1, value.bitPattern))
        // 目标 = 尾部（本方法被调用时的 offset）
        let target = bytes.count
        let rel = target - record.1
        let imm19 = UInt32(bitPattern: Int32(rel / 4)) & 0x7FFFF
        patch(record.1, 0x1C00_0000 | (imm19 << 5) | record.0)
        bytes.append(UInt8(value.bitPattern & 0xFF))
        bytes.append(UInt8((value.bitPattern >> 8) & 0xFF))
        bytes.append(UInt8((value.bitPattern >> 16) & 0xFF))
        bytes.append(UInt8((value.bitPattern >> 24) & 0xFF))
    }
}
