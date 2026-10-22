//
//  JITAvailability.swift
//  PipaRender — JIT 运行时探测与降级决策
//
//  探测三级（零自动崩溃风险）：
//    1. mapProbe    mmap(MAP_JIT) 是否成功（无 entitlement 的普通签名安装在此失败）——启动时自动，不执行代码
//    2. runProbe    执行最小探针（mov w0,#42; ret）——仅在检测到调试器附着时自动执行，
//                   或用户在设置里手动点"测试 JIT"。iOS 上无调试器时探针段错误会杀进程，
//                   因此绝不静默自动执行；崩溃恢复标记防止二次尝试。
//    3. enabled     探针返回 42 → 渲染循环走 JIT 内核；否则全程 Swift 参考实现。
//

import Foundation

public enum JITAvailability {

    public enum State: Equatable {
        case unavailable          // MAP_JIT 都建不了（普通签名安装 / 系统版本过新）
        case mappable             // 能映射未探针（多半没开调试器）
        case enabled              // 探针通过，JIT 内核生效
        case disabled             // 用户手动关闭
    }

    // MARK: - 持久化（崩溃恢复：探针中崩溃 -> 下次启动不再自动探针）

    private static let enabledKey = "jit.enabled"
    private static let probeCrashKey = "jit.probeCrashed"

    /// 探针前调用：写"探针进行中"标记
    public static func markProbeStart() {
        UserDefaults.standard.set(true, forKey: probeCrashKey)
    }

    /// 探针成功后调用：清标记
    public static func markProbeOK() {
        UserDefaults.standard.set(false, forKey: probeCrashKey)
    }

    /// 上次是否探针崩溃（启动时检测，决定是否还敢自动探针）
    public static var lastProbeCrashed: Bool {
        UserDefaults.standard.bool(forKey: probeCrashKey)
    }

    // MARK: - 探测

    /// mmap(MAP_JIT) 能力探测（不执行任何代码，零风险）
    public static func mapProbe() -> Bool {
        #if canImport(Darwin)
        var pageSize = Int(vm_page_size)
        let p = mmap(nil, pageSize, PROT_READ | PROT_WRITE,
                     MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0)
        guard p != MAP_FAILED else { return false }
        munmap(p, pageSize)
        return true
        #else
        return false     // 非 Darwin（CI x86_64）：不解执行
        #endif
    }

    /// 执行最小探针：mov w0, #42; ret。返回 42 视为 JIT 放行。
    /// 注意：iOS 上无调试器时本函数会段错误杀进程——只能由用户显式触发
    ///（或 markProbeStart 崩溃恢复保护下的调试器自动路径）。
    public static func runProbe() -> Bool {
        #if canImport(Darwin)
        // MOVZ W0, #42 ; RET
        let probe: [UInt8] = [0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6]
        do {
            let page = try JITEngine.makeExecutable(probe)
            var result: Int32 = 0
            page.call { ptr in
                result = unsafeBitCast(ptr, to: (@convention(c) () -> Int32).self)()
            }
            return result == 42
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    /// 当前状态（持久化的用户选择 + map 探测）
    public static var state: State {
        if UserDefaults.standard.bool(forKey: enabledKey) { return .enabled }
        return mapProbe() ? .mappable : .unavailable
    }

    /// 渲染循环查询：是否走 JIT 内核
    public static var isEnabled: Bool {
        state == .enabled
    }

    /// 用户手动测试（设置页按钮）：通过则持久化启用
    @discardableResult
    public static func testAndEnable() -> Bool {
        markProbeStart()
        let ok = runProbe()
        if ok {
            markProbeOK()
            UserDefaults.standard.set(true, forKey: enabledKey)
        }
        return ok
    }

    /// 用户手动停用
    public static func disable() {
        UserDefaults.standard.set(false, forKey: enabledKey)
    }

    // MARK: - 调试器附着检测（决定启动时能否自动探针）

    /// iOS：sysctl KERN_PROC 查 P_TRACED。StikDebug 在 app 启动前附着，
    /// 启动时即可检出——此时自动探针是安全的（用户有意开了 JIT）。
    public static var isDebuggerAttached: Bool {
        #if canImport(Darwin) && !os(macOS)
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard rc == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
        #else
        return false
        #endif
    }
}
