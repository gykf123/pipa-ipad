//
//  VideoExporter.swift
//  PipaRender — AVAssetWriter 分段编码 + AVMutableComposition 合并 + BGM 混合
//

import Foundation
import AVFoundation
import CoreVideo
import UIKit

/// 一段视频的编码器（H.264 硬件编码，iPad A10 支持）
final class SegmentWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let pool: CVPixelBufferPool?
    let width: Int
    let height: Int
    private(set) var frameCount = 0

    init(url: URL, width: Int, height: Int, fps: Int) throws {
        self.width = width; self.height = height
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let attrs: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(width * height * 11, 24_000_000),  // 1080p ≈ 24Mbps
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: attrs)
        input.expectsMediaDataInRealTime = false
        input.transform = .identity
        let srcAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: srcAttrs)
        pool = adaptor.pixelBufferPool
        guard writer.canAdd(input) else { throw PackageError.metalFailure("AVAssetWriter 无法添加视频轨") }
        writer.add(input)
        guard writer.startWriting() else {
            throw PackageError.metalFailure("AVAssetWriter 启动失败：\(writer.error?.localizedDescription ?? "")")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// 渲染并追加一帧（阻塞到编码队列就绪）
    func append(sourceFrame: Float, renderer: MetalRenderer) throws {
        guard let pool = pool else { throw PackageError.metalFailure("pixelBufferPool 不可用") }
        var pbOut: CVPixelBuffer?
        var status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        var tries = 0
        while status != kCVReturnSuccess || pbOut == nil {
            if tries > 100 { throw PackageError.metalFailure("pixelBufferPool 耗尽") }
            usleep(2000)
            status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            tries += 1
        }
        try renderer.renderAndWait(sourceFrame: sourceFrame, pixelBuffer: pbOut!)
        // 等待输入就绪
        tries = 0
        while !input.isReadyForMoreMediaData {
            if tries > 500 { throw PackageError.metalFailure("编码输入持续未就绪") }
            usleep(2000)
            tries += 1
        }
        let pts = CMTime(value: CMTimeValue(frameCount), timescale: renderer.settings.outputFPS)
        guard adaptor.append(pbOut!, withPresentationTime: pts) else {
            throw PackageError.metalFailure("追加帧失败：\(writer.error?.localizedDescription ?? "")")
        }
        frameCount += 1
    }

    func finish() throws {
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed {
            throw PackageError.metalFailure("写段失败：\(writer.error?.localizedDescription ?? "")")
        }
    }
}

/// 全片合成：各段视频顺序拼接 + BGM（可选）
enum VideoComposer {
    /// 合并分段 mp4；audioURL 非空时混入音频（静音补齐到视频时长）
    static func compose(segmentURLs: [URL], output: URL, audioURL: URL?, fps: Int) throws -> URL {
        let comp = AVMutableComposition()
        guard let vtrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackIDInvalid) else {
            throw PackageError.corruptData("无法创建视频轨")
        }
        var cursor = CMTime.zero
        var totalDuration = CMTime.zero
        for url in segmentURLs {
            let asset = AVURLAsset(url: url)
            let dur = asset.duration
            let range = CMTimeRange(start: .zero, duration: dur)
            if let t = asset.tracks(withMediaType: .video).first {
                try vtrack.insertTimeRange(range, of: t, at: cursor)
            }
            cursor = cursor + dur
            totalDuration = cursor
        }
        if let audioURL = audioURL {
            let aAsset = AVURLAsset(url: audioURL)
            let aDur = aAsset.duration
            if let at = aAsset.tracks(withMediaType: .audio).first,
               let atrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackIDInvalid) {
                let useDur = CMTimeMinimum(aDur, totalDuration)
                try atrack.insertTimeRange(CMTimeRange(start: .zero, duration: useDur), of: at, at: .zero)
            }
        }
        guard let exp = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw PackageError.metalFailure("导出会话创建失败")
        }
        exp.outputURL = output
        exp.outputFileType = .mp4
        try? FileManager.default.removeItem(at: output)
        let sem = DispatchSemaphore(value: 0)
        exp.exportAsynchronously { sem.signal() }
        sem.wait()
        guard exp.status == .completed else {
            throw PackageError.metalFailure("合成失败：\(exp.error?.localizedDescription ?? "")")
        }
        return output
    }
}
