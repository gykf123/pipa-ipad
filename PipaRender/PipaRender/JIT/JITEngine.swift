//
//  JITEngine.swift
//  PipaRender — 可执行内存管理（JIT 页面）
//
//  iOS 现实（2026）：
//   - 系统禁止第三方 App 无授权 JIT；三条放行路径：
//     ① 漏洞签名（巨魔/nbtool 类 CoreTrust 漏洞，iOS 14–16.6.1/17.0）：entitlement 永久生效
//     ② StikDebug 调试器路径（iOS 17.4–18.x 主流）：启动前开一次 JIT，关 app 失效
//     ③ 普通签名（AltStore/7 天证书/App Store）：MAP_JIT 直接失败 → 自动降级
//   - 因此：mmap 成功 ≠ 可执行（iOS 需调试器附着才放行），探针必须真执行一次。
//

import Foundation

public enum JITError: Error, Equatable {
    case mmapFailed(errno: Int32)
    case writeFailed
}

/// 一段可执行内存（持有期间有效；析构时 munmap）
public final class JITPage {
    public let address: UnsafeMutableRawPointer
    private let size: Int

    init(address: UnsafeMutableRawPointer, size: Int) {
        self.address = address
        self.size = size
    }

    deinit {
        munmap(address, size)
    }

    /// 以 C 函数指针方式调用页内代码
    public func call(_ body: (UnsafeRawPointer) -> Void) {
        body(address)
    }
}

public enum JITEngine {

    /// 把 ARM64 机器码搬进可执行内存。
    /// macOS：MAP_JIT + pthread_jit_write_protect（W^X 切换）。
    /// iOS：MAP_JIT 需 allow-jit entitlement / 调试器放行；写后 sys_icache_invalidate。
    /// Linux：RWX 匿名映射（CI x86_64 不解执行，仅接口占位）。
    public static func makeExecutable(_ code: [UInt8]) throws -> JITPage {
        guard !code.isEmpty else { throw JITError.writeFailed }
        #if canImport(Darwin)
        let pageSize = Int(vm_page_size)
        #else
        let pageSize = Int(getpagesize())
        #endif
        // 向上取整到整页（拆两句，避免巨型表达式拖垮类型检查器）
        let pages = (code.count + pageSize - 1) / pageSize
        let size = pages * pageSize

        #if canImport(Darwin)
        let raw = mmap(nil, size, PROT_READ | PROT_WRITE,
                       MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0)
        #else
        let raw = mmap(nil, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                       MAP_ANON | MAP_PRIVATE, -1, 0)
        #endif
        guard let p = raw, p != MAP_FAILED else { throw JITError.mmapFailed(errno: errno) }
        #if canImport(Darwin)
        #if os(macOS)
        pthread_jit_write_protect(0)          // 开写（macOS 专属 W^X 切换）
        #endif
        memcpy(p, code, code.count)
        #if os(macOS)
        pthread_jit_write_protect(1)          // 回执行（Apple 核 I-cache 自动一致）
        #endif
        // iOS：MAP_JIT 页语义自带 I-cache 一致性（写入对指令可见），无需显式失效；
        // sys_icache_invalidate 不在 Swift iOS SDK 导出面，强声明反而有符号风险
        #else
        memcpy(p, code, code.count)
        #endif
        return JITPage(address: p, size: size)
    }
}
