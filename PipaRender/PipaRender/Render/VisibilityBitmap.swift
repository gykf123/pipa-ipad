//
//  VisibilityBitmap.swift
//  PipaRender — 打包期烘焙的每帧组可见性位图（保守遮挡剔除）
//

import Foundation

final class VisibilityBitmap {
    private let words: [UInt64]
    private let groups: Int
    private let wordsPerFrame: Int

    init?(data: Data, groups: Int, frames: Int) {
        guard groups > 0, frames > 0 else { return nil }
        let wpf = (groups + 63) / 64
        guard data.count >= wpf * frames * 8 else { return nil }
        self.groups = groups
        self.wordsPerFrame = wpf
        words = data.withUnsafeBytes { raw -> [UInt64] in
            let p = raw.bindMemory(to: UInt64.self).baseAddress!
            return Array(UnsafeBufferPointer(start: p, count: wpf * frames))
        }
    }

    /// 第 f 帧（0 基）第 g 组是否可能可见；无数据时按保守可见
    func isVisible(frame f: Int, group g: Int) -> Bool {
        guard g >= 0, g < groups else { return true }
        let w = words[f * wordsPerFrame + g / 64]
        return (w >> UInt64(g % 64)) & 1 == 1
    }
}
