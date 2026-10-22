//
//  main.swift — JIT 内核真执行验证（macOS arm64 runner）
//
//  读 jit_encode_check 产出的数据文件，mmap 执行 ARM64 内核，与 Swift 参考输出逐元素对比。
//  必须 ad-hoc codesign 带 com.apple.security.cs.allow-jit（macOS 上该 entitlement
//  即可放行 JIT，无需调试器；iOS 侧才需要调试器/漏洞签名）。
//  文件须名 main.swift：多文件编译只允许 main.swift 含顶层代码。
//

import Foundation
import simd

func readFile(_ name: String) -> Data {
    let url = URL(fileURLWithPath: name)
    guard let d = try? Data(contentsOf: url) else {
        print("FAIL 读不到 \(name)"); exit(2)
    }
    return d
}

let code = readFile("jit_code.bin")
let track = readFile("jit_track.bin")
let arm = readFile("jit_arm.bin")
let expectedText = (try? String(contentsOf: URL(fileURLWithPath: "jit_expected.txt"), encoding: .utf8)) ?? ""
let expectedRows = expectedText.split(separator: "\n").map { $0.split(separator: ",").map { Float($0)! } }

let frames = 3, nbones = 4
let armFloats = arm.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
// jit_arm.bin 为行主序 16 floats（RenderMath 的 init(rowMajor:) 转列主序存储）
let aw = simd_float4x4(rowMajor: armFloats)

guard let page = try? JITEngine.makeExecutable([UInt8](code)) else {
    print("FAIL makeExecutable"); exit(2)
}
print("page=\(page.address) code=\(code.count)B track=\(track.count)B arm=\(arm.count)B")

var maxErr: Float = 0
var failed = false
for fi in 0..<frames {
    var out = [Float](repeating: 0, count: nbones * 16)
    let trackPtr = track.withUnsafeBytes { $0.bindMemory(to: Float.self).baseAddress! }
    let ok = out.withUnsafeMutableBufferPointer { outBuf -> Bool in
        guard let outPtr = outBuf.baseAddress else { return false }
        var awCopy = aw
        page.call { ptr in
            // 内核 ABI 跳过 x5（见 JITKernels 头注）：INT 参数序列必须显式占位一个
            // Int32，否则 armatureWorld 落 x5 / out 落 x6，内核读 x6/x7 即总线错误。
            typealias Fn = @convention(c) (
                UnsafeRawPointer, Int32, Int32, Int32, Int32, Float,
                Int32,
                UnsafeRawPointer, UnsafeMutablePointer<Float>) -> Void
            let fn = unsafeBitCast(ptr, to: Fn.self)
            fn(trackPtr, 0, Int32(frames), Int32(nbones), 0, Float(fi),
               0,
               withUnsafePointer(to: &awCopy) { UnsafeRawPointer($0) }, outPtr)
        }
        return true
    }
    guard ok else { print("FAIL call"); exit(2) }
    let ref = expectedRows[fi * nbones..<(fi + 1) * nbones]
    for (bi, row) in ref.enumerated() {
        for c in 0..<16 {
            let e = abs(out[bi * 16 + c] - row[c])
            maxErr = max(maxErr, e)
            if e > 1e-4 {
                print("FAIL frame=\(fi) bone=\(bi) col=\(c): jit=\(out[bi*16+c]) ref=\(row[c])")
                failed = true
            }
        }
    }
}
print(failed ? "JIT EXEC: FAIL" : "JIT EXEC: ALL PASS (max_err=\(maxErr))")
exit(failed ? 2 : 0)
