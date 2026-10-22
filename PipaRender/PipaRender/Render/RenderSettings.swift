//
//  RenderSettings.swift
//  PipaRender — 渲染任务设置 + 质量档（"渲染最大占用"映射）
//

import Foundation

/// 质量档：占用率 -> 内部渲染分辨率 / SSAO 采样 / 阴影分辨率 / 泛光开关
struct QualityProfile {
    var scale: Float            // 内部渲染分辨率倍率（相对输出分辨率）
    var aoSamples: Int
    var shadowMapSize: Int      // 每级阴影贴图边长
    var shadowSamples: Int
    var bloom: Bool
    var glare: Bool

    /// 30%–100% 占用率映射（五档；热控在此基础上再降档）
    static func profile(occupancy: Float) -> QualityProfile {
        let o = min(max(occupancy, 0.3), 1.0)
        switch o {
        case 0.3..<0.45:
            return QualityProfile(scale: 0.40, aoSamples: 4, shadowMapSize: 256, shadowSamples: 4,
                                  bloom: false, glare: false)
        case 0.45..<0.65:
            return QualityProfile(scale: 0.55, aoSamples: 8, shadowMapSize: 512, shadowSamples: 6,
                                  bloom: true, glare: false)
        case 0.65..<0.8:
            return QualityProfile(scale: 0.70, aoSamples: 12, shadowMapSize: 512, shadowSamples: 8,
                                  bloom: true, glare: true)
        case 0.8..<0.9:
            return QualityProfile(scale: 0.85, aoSamples: 16, shadowMapSize: 768, shadowSamples: 12,
                                  bloom: true, glare: true)
        default:
            return QualityProfile(scale: 1.0, aoSamples: 24, shadowMapSize: 1024, shadowSamples: 16,
                                  bloom: true, glare: true)
        }
    }

    /// 热控降档（连续降一档，30% 封顶）
    func reduced() -> QualityProfile {
        var o = scale
        if o >= 1.0 { o = 0.85 } else if o >= 0.85 { o = 0.7 } else if o >= 0.7 { o = 0.55 }
        else if o >= 0.55 { o = 0.4 } else { o = 0.3 }
        return QualityProfile.profile(occupancy: o)
    }
}

/// 一个渲染任务的完整设置
struct RenderSettings: Codable {
    var outputFPS: Int = 30              // 成品帧率（24/30/60）
    var occupancy: Float = 0.7           // 渲染最大占用 0.3–1.0
    var sourceStart: Int = 0             // 源帧范围（0 基，相对 frame_start，含）
    var sourceEnd: Int = 0               // 含
    var segmentLength: Int = 90          // 分段帧数（断点续跑粒度）
    var includeAudio: Bool = true

    /// 输出帧数（源帧按比例抽帧：源索引 = start + floor(i × src/out)，≤ span-1）
    func outputFrameCount(sourceFPS: Int) -> Int {
        let span = sourceEnd - sourceStart + 1
        guard outputFPS > 0, sourceFPS > 0, span > 0 else { return max(span, 0) }
        return Int(ceil(Float(span) * Float(outputFPS) / Float(sourceFPS)))
    }

    /// 输出帧 i 对应的源帧号（float，供骨骼插值；整数供 movers/粒子）
    func sourceFrame(outputIndex i: Int, sourceFPS: Int) -> Float {
        Float(sourceStart) + floorf(Float(i) * Float(sourceFPS) / Float(outputFPS))
    }
}

/// 热控状态（JobManager 每段检查）
struct ThermalGovernor {
    var level: Int = 0                   // 0 正常，1/2/3 逐步降档

    /// 由 ProcessInfo 热状态 + 帧耗时决定升降档
    mutating func update(thermalState: ProcessInfo.ThermalState, avgFrameMs: Double) {
        switch thermalState {
        case .critical:
            level = max(level, 3)
        case .serious:
            level = max(level, 2)
        case .fair:
            level = max(level, 1)
        case .nominal:
            if avgFrameMs < 40 { level = 0 } else if avgFrameMs < 80 { level = min(level, 1) }
        @unknown default:
            break
        }
    }

    /// 应用降档：占用率乘以衰减系数
    func apply(to occupancy: Float) -> Float {
        let factor: Float = [1.0, 0.8, 0.6, 0.4][min(level, 3)]
        return max(0.3, occupancy * factor)
    }
}
