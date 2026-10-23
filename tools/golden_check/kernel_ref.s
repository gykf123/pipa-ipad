//
//  kernel_ref.s — JITKernels.skinningCode() 的权威参考实现（ARMv8-A 汇编）
//
//  本文件与 PipaRender/PipaRender/JIT/JITKernels.swift 逐条对应（同一指令流、
//  同一 literal 尾部布局）。clang 汇编本文件得到 .text 字节，应与 Swift 汇编器
//  生成的机器码完全一致（golden-bytes 对比，见 golden_diff.py）。
//
//  意义：JITAssembler 是手写指令编码器，曾把不存在的 GP 寄存器 SMAX/SMIN 编成
//  0x1B004000/0x1B005000（A64 只有 SIMD 向量形式有此名，真机必 SIGILL）。
//  本参考文件 + clang 交叉汇编可从机制上杜绝此类错误：任何编码偏差都会在
//  字节级 diff 中暴露。
//
//  C ABI（与 Swift 侧 @convention(c) 调用一致）：
//    x0 = const float* track | w1 = charOffsetFloats | w2 = frames
//    w3 = boneCount | w4 = frameStart | s0 = frame | x6 = armatureWorld | x7 = out
//
//  寄存器约定（与 JITKernels.swift 注释一致）：
//    w8 = a | w9 = frames-1 | w10 = bone | w11 = 骨指针 | w12 = 临时
//    s0-s3 = q | s4-s6 = t | s7 = ns | s8-s16 = R 9 元素 | s17 = 1e-20
//    s18-s19/s23-s29 = 中间量 | s20-s22 = s | s24-s27 = 行内 | s28/s30/s31 = 累加/临时/常量
//

    .arch armv8-a
    .text
    .globl _kernel
    .p2align 2
_kernel:
    // ---- 序言：a = clamp(round(frame) - frameStart, 0, frames-1) ----
    fcvtas  w8, s0                     // w8 = lround(frame)
    sub     w8, w8, w4                 // - frameStart
    cmp     w8, #0
    csel    w8, wzr, w8, lt            // max(., 0)
    sub     w9, w2, #1                 // frames - 1
    cmp     w8, w9
    csel    w8, w9, w8, gt             // min(., frames-1)
    movz    w10, #0                    // bone index = 0
    ldr     s17, 1f                    // s17 = 1e-20

.Lloop:
    // 骨 track 指针：x11 = x0 + (a*bones+bone)*40 + charOff*4
    madd    w12, w8, w3, w10           // w12 = a*bones + bone
    orr     x12, xzr, x12, lsl #3      // ×8（JITAssembler.lsl64 生成 ORR 别名形式；clang 规范化成 UBFM，语义等价）
    add     x12, x12, x12, lsl #2      // ×5（×8 + ×32 = ×40；原 lsl #3 误算成 ×288，bone≥1 越界读脏数据）
    add     x11, x0, x12
    add     x11, x11, x1, lsl #2       // + charOff*4

    // q4 + t3 + s3
    ldr     s0, [x11, 0]
    ldr     s1, [x11, 4]
    ldr     s2, [x11, 8]
    ldr     s3, [x11, 12]
    ldr     s4, [x11, 16]
    ldr     s5, [x11, 20]
    ldr     s6, [x11, 24]
    ldr     s20, [x11, 28]
    ldr     s21, [x11, 32]
    ldr     s22, [x11, 36]

    // n = q·q; ns = 2 / max(n, 1e-20)
    fmul    s7, s0, s0
    fmadd    s7, s1, s1, s7
    fmadd    s7, s2, s2, s7
    fmadd    s7, s3, s3, s7
    fmax    s7, s7, s17
    fmov    s31, #2.0
    fdiv    s7, s31, s7

    // 中间量：xx yy zz xy xz yz wx wy wz
    fmul    s18, s0, s0
    fmul    s19, s1, s1
    fmul    s23, s2, s2
    fmul    s24, s0, s1
    fmul    s25, s0, s2
    fmul    s26, s1, s2
    fmul    s27, s3, s0
    fmul    s28, s3, s1
    fmul    s29, s3, s2

    // R 9 元素（R00=s8 R01=s9 R02=s10 R10=s11 R11=s12 R12=s13 R20=s14 R21=s15 R22=s16）
    fadd    s30, s19, s23
    fmul    s30, s30, s7
    fmov    s31, #1.0
    fsub    s8, s31, s30              // r00 = 1-(yy+zz)*ns
    fadd    s30, s18, s23
    fmul    s30, s30, s7
    fsub    s12, s31, s30             // r11 = 1-(xx+zz)*ns
    fadd    s30, s18, s19
    fmul    s30, s30, s7
    fsub    s16, s31, s30             // r22 = 1-(xx+yy)*ns
    fsub    s30, s24, s29
    fmul    s9, s30, s7               // r01 = (xy-wz)*ns
    fadd    s30, s24, s29
    fmul    s11, s30, s7              // r10 = (xy+wz)*ns
    fadd    s30, s25, s28
    fmul    s10, s30, s7              // r02 = (xz+wy)*ns
    fsub    s30, s25, s28
    fmul    s14, s30, s7              // r20 = (xz-wy)*ns
    fsub    s30, s26, s27
    fmul    s13, s30, s7              // r12 = (yz-wx)*ns
    fadd    s30, s26, s27
    fmul    s15, s30, s7              // r21 = (yz+wx)*ns

    // ---- out 行 0：<- X 行 0（正），A 行 0，col2 取负 ----
    ldr     s24, [x6, 0]
    ldr     s25, [x6, 4]
    ldr     s26, [x6, 8]
    ldr     s27, [x6, 12]
    fmul    s24, s24, s20
    fmul    s25, s25, s21
    fmul    s26, s26, s22
    fmul    s28, s24, s8
    fmadd    s28, s25, s11, s28
    fmadd    s28, s26, s14, s28
    str     s28, [x7, 0]
    fmul    s28, s24, s10
    fmadd    s28, s25, s13, s28
    fmadd    s28, s26, s16, s28
    str     s28, [x7, 4]
    fmul    s28, s24, s9
    fmadd    s28, s25, s12, s28
    fmadd    s28, s26, s15, s28
    fneg    s28, s28
    str     s28, [x7, 8]
    ldr     s28, [x6, 0]
    fmul    s28, s28, s4
    ldr     s29, [x6, 4]
    fmul    s29, s29, s5
    ldr     s30, [x6, 8]
    fmul    s30, s30, s6
    fadd    s28, s28, s29
    fadd    s28, s28, s30
    fadd    s28, s28, s27
    str     s28, [x7, 12]

    // ---- out 行 1：<- X 行 2（正），A 行 2，col2 取负 ----
    ldr     s24, [x6, 32]
    ldr     s25, [x6, 36]
    ldr     s26, [x6, 40]
    ldr     s27, [x6, 44]
    fmul    s24, s24, s20
    fmul    s25, s25, s21
    fmul    s26, s26, s22
    fmul    s28, s24, s8
    fmadd    s28, s25, s11, s28
    fmadd    s28, s26, s14, s28
    str     s28, [x7, 16]
    fmul    s28, s24, s10
    fmadd    s28, s25, s13, s28
    fmadd    s28, s26, s16, s28
    str     s28, [x7, 20]
    fmul    s28, s24, s9
    fmadd    s28, s25, s12, s28
    fmadd    s28, s26, s15, s28
    fneg    s28, s28
    str     s28, [x7, 24]
    ldr     s28, [x6, 32]
    fmul    s28, s28, s4
    ldr     s29, [x6, 36]
    fmul    s29, s29, s5
    ldr     s30, [x6, 40]
    fmul    s30, s30, s6
    fadd    s28, s28, s29
    fadd    s28, s28, s30
    fadd    s28, s28, s27
    str     s28, [x7, 28]

    // ---- out 行 2：<- X 行 1（负），A 行 1，col0/col1/col3 取负 ----
    ldr     s24, [x6, 16]
    ldr     s25, [x6, 20]
    ldr     s26, [x6, 24]
    ldr     s27, [x6, 28]
    fmul    s24, s24, s20
    fmul    s25, s25, s21
    fmul    s26, s26, s22
    fmul    s28, s24, s8
    fmadd    s28, s25, s11, s28
    fmadd    s28, s26, s14, s28
    fneg    s28, s28
    str     s28, [x7, 32]
    fmul    s28, s24, s10
    fmadd    s28, s25, s13, s28
    fmadd    s28, s26, s16, s28
    fneg    s28, s28
    str     s28, [x7, 36]
    fmul    s28, s24, s9
    fmadd    s28, s25, s12, s28
    fmadd    s28, s26, s15, s28
    str     s28, [x7, 40]
    ldr     s28, [x6, 16]
    fmul    s28, s28, s4
    ldr     s29, [x6, 20]
    fmul    s29, s29, s5
    ldr     s30, [x6, 24]
    fmul    s30, s30, s6
    fadd    s28, s28, s29
    fadd    s28, s28, s30
    fadd    s28, s28, s27
    fneg    s28, s28
    str     s28, [x7, 44]

    // ---- out 行 3：<- X 行 3（正），A 行 3，col2 取负 ----
    ldr     s24, [x6, 48]
    ldr     s25, [x6, 52]
    ldr     s26, [x6, 56]
    ldr     s27, [x6, 60]
    fmul    s24, s24, s20
    fmul    s25, s25, s21
    fmul    s26, s26, s22
    fmul    s28, s24, s8
    fmadd    s28, s25, s11, s28
    fmadd    s28, s26, s14, s28
    str     s28, [x7, 48]
    fmul    s28, s24, s10
    fmadd    s28, s25, s13, s28
    fmadd    s28, s26, s16, s28
    str     s28, [x7, 52]
    fmul    s28, s24, s9
    fmadd    s28, s25, s12, s28
    fmadd    s28, s26, s15, s28
    fneg    s28, s28
    str     s28, [x7, 56]
    ldr     s28, [x6, 48]
    fmul    s28, s28, s4
    ldr     s29, [x6, 52]
    fmul    s29, s29, s5
    ldr     s30, [x6, 56]
    fmul    s30, s30, s6
    fadd    s28, s28, s29
    fadd    s28, s28, s30
    fadd    s28, s28, s27
    str     s28, [x7, 60]

    // 循环尾
    add     x7, x7, #64                // out += 64
    add     w10, w10, #1               // bone++
    cmp     w10, w3
    b.lt    .Lloop
    ret
1:  .float 1e-20                       // literal 池（位模式 0x0E0E2A16）
