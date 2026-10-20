//
//  JobManager.swift
//  PipaRender — 渲染任务：分段断点续跑 + 热控降档 + 状态持久化 + 成品合成
//

import Foundation
import Metal
import Photos
import UIKit

final class JobManager: ObservableObject {
    static let shared = JobManager()

    @Published private(set) var jobs: [RenderJob] = []

    private let renderQueue = DispatchQueue(label: "cn.pipa.render", qos: .userInitiated)
    private var governor = ThermalGovernor()
    private var activeJob: RenderJob?

    private init() {
        restoreJobs()
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.governor.level = max(self?.governor.level ?? 0, 1)   // 退后台降一档
        }
    }

    // MARK: - 任务模型

    final class RenderJob: ObservableObject, Identifiable {
        let id: String
        let pkg: ImportedPackage
        var settings: RenderSettings
        @Published private(set) var status: Status
        @Published private(set) var progress: Double = 0
        @Published private(set) var segmentIndex = 0
        @Published private(set) var message = ""
        @Published private(set) var outputURL: URL?
        var segments: [SegmentState]
        let createdAt: Date

        enum Status: String, Codable {
            case pending, running, completed, failed, canceled
        }

        struct SegmentState: Codable {
            var index: Int
            var startFrame: Int      // 输出帧（global，含）
            var endFrame: Int        // exclusive
            var file: String         // 段 mp4 文件名
            var done: Bool
        }

        init(id: String, pkg: ImportedPackage, settings: RenderSettings, segments: [SegmentState]) {
            self.id = id
            self.pkg = pkg
            self.settings = settings
            self.segments = segments
            self.status = .pending
            self.createdAt = Date()
        }

        var doneFrames: Int {
            segments.filter { $0.done }.reduce(0) { $0 + ($1.endFrame - $1.startFrame) }
        }
        var totalFrames: Int {
            segments.reduce(0) { $0 + ($1.endFrame - $1.startFrame) }
        }

        func update(status: Status? = nil, progress: Double? = nil, segment: Int? = nil,
                    message: String? = nil, output: URL? = nil) {
            DispatchQueue.main.async {
                if let s = status { self.status = s }
                if let p = progress { self.progress = p }
                if let g = segment { self.segmentIndex = g }
                if let m = message { self.message = m }
                if let o = output { self.outputURL = o }
            }
        }
    }

    // MARK: - 持久化

    private struct JobFile: Codable {
        var id: String
        var packageId: String
        var settings: RenderSettings
        var segments: [RenderJob.SegmentState]
        var status: RenderJob.Status
    }

    private func jobFileURL(_ p: ImportedPackage, _ jobId: String) -> URL {
        PackageStore.shared.jobDirectory(p, jobId: jobId).appendingPathComponent("job.json")
    }

    private func persist(_ job: RenderJob) {
        let f = JobFile(id: job.id, packageId: job.pkg.id.uuidString, settings: job.settings,
                        segments: job.segments, status: job.status)
        if let data = try? JSONEncoder().encode(f) {
            try? data.write(to: jobFileURL(job.pkg, job.id))
        }
    }

    /// 扫描包目录恢复未完成任务
    private func restoreJobs() {
        var out: [RenderJob] = []
        for p in PackageStore.shared.packages {
            let jobsDir = p.directory.appendingPathComponent("jobs", isDirectory: true)
            guard let subs = try? FileManager.default.contentsOfDirectory(at: jobsDir, includingPropertiesForKeys: nil) else { continue }
            for dir in subs {
                let metaURL = dir.appendingPathComponent("job.json")
                guard let data = try? Data(contentsOf: metaURL),
                      let f = try? JSONDecoder().decode(JobFile.self, from: data),
                      f.packageId == p.id.uuidString else { continue }
                // 段文件缺失的段标记为未完成
                var segs = f.segments
                for i in segs.indices {
                    let url = dir.appendingPathComponent(segs[i].file)
                    if !FileManager.default.fileExists(atPath: url.path) { segs[i].done = false }
                }
                let job = RenderJob(id: f.id, pkg: p, settings: f.settings, segments: segs)
                if f.status == .completed {
                    job.update(status: .completed, progress: 1, output: dir.appendingPathComponent("output.mp4"))
                } else if f.status == .running {
                    job.update(status: .pending)     // 中断的任务回退为待续跑
                } else {
                    job.update(status: f.status)
                }
                out.append(job)
            }
        }
        jobs = out.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - 创建 / 控制

    @discardableResult
    func createJob(pkg: ImportedPackage, settings: RenderSettings) -> RenderJob {
        let srcFPS = pkg.pkg.fps
        let nOut = settings.outputFrameCount(sourceFPS: srcFPS)
        var segs: [RenderJob.SegmentState] = []
        var i = 0
        while i < nOut {
            let end = min(i + settings.segmentLength, nOut)
            segs.append(RenderJob.SegmentState(index: segs.count, startFrame: i, endFrame: end,
                                               file: String(format: "seg_%04d.mp4", segs.count), done: false))
            i = end
        }
        let id = UUID().uuidString
        let job = RenderJob(id: id, pkg: pkg, settings: settings, segments: segs)
        jobs.insert(job, at: 0)
        persist(job)
        return job
    }

    func start(_ job: RenderJob) {
        guard activeJob == nil else { return }
        activeJob = job
        job.update(status: .running, progress: Double(job.doneFrames) / Double(max(job.totalFrames, 1)))
        renderQueue.async { [weak self] in
            self?.runJob(job)
        }
    }

    func resume(_ job: RenderJob) { start(job) }

    func cancel(_ job: RenderJob) {
        guard let active = activeJob, active.id == job.id else {
            job.update(status: .canceled)
            persist(job)
            return
        }
        job.update(status: .canceled, message: "已取消")
        persist(job)
        // 渲染队列中的段会在下一段检查时退出
    }

    func delete(_ job: RenderJob) {
        cancel(job)
        jobs.removeAll { $0.id == job.id }
        let dir = PackageStore.shared.jobDirectory(job.pkg, jobId: job.id)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 渲染循环

    private func runJob(_ job: RenderJob) {
        defer {
            DispatchQueue.main.async {
                self.activeJob = nil
            }
        }
        do {
            let device = MTLCreateSystemDefaultDevice()
            guard let device = device else { throw PackageError.metalFailure("Metal 设备不可用") }
            let assets = try SceneAssets(device: device, package: job.pkg)
            var settings = job.settings
            // 热控降档
            let occ = governor.apply(to: settings.occupancy)
            settings.occupancy = occ
            let renderer = try MetalRenderer(device: device, assets: assets, settings: settings)
            renderer.usePackageCamera = true
            let p = job.pkg.pkg
            let outW = p.width, outH = p.height
            renderer.setOutputSize(w: outW, h: outH)
            let srcFPS = p.fps
            let total = max(job.totalFrames, 1)

            let jobDir = PackageStore.shared.jobDirectory(job.pkg, jobId: job.id)
            var segmentURLs: [URL] = []
            // 已完成的段直接入列
            for s in job.segments where s.done {
                segmentURLs.append(jobDir.appendingPathComponent(s.file))
            }

            for si in job.segments.indices {
                if job.status == .canceled { return }
                let seg = job.segments[si]
                if seg.done { continue }
                job.update(segment: seg.index, message: "热控 L\(governor.level) · 段 \(seg.index + 1)/\(job.segments.count)")
                persist(job)
                let segURL = jobDir.appendingPathComponent(seg.file)
                let writer = try SegmentWriter(url: segURL, width: outW, height: outH, fps: settings.outputFPS)
                var frameMs: [Double] = []
                for outFrame in seg.startFrame..<seg.endFrame {
                    if job.status == .canceled { return }
                    let srcFrame = settings.sourceFrame(outputIndex: outFrame, sourceFPS: srcFPS)
                    let t0 = Date()
                    try writer.append(sourceFrame: srcFrame, renderer: renderer)
                    frameMs.append(Date().timeIntervalSince(t0) * 1000)
                    if frameMs.count > 30 { frameMs.removeFirst(min(10, frameMs.count)) }
                    let avg = frameMs.reduce(0, +) / Double(frameMs.count)
                    governor.update(thermalState: ProcessInfo.processInfo.thermalState, avgFrameMs: avg)
                    job.update(progress: Double(seg.startFrame + (outFrame - seg.startFrame) + 1 + job.doneFrames) / Double(total))
                }
                try writer.finish()
                job.segments[si].done = true
                segmentURLs.append(segURL)
                persist(job)
                // 段间热控冷却检查
                governor.update(thermalState: ProcessInfo.processInfo.thermalState, avgFrameMs: 0)
            }

            // 合成
            job.update(message: "合成成品…")
            let outURL = jobDir.appendingPathComponent("output.mp4")
            let audio = settings.includeAudio ? job.pkg.audioURL() : nil
            _ = try VideoComposer.compose(segmentURLs: segmentURLs, output: outURL,
                                          audioURL: audio, fps: settings.outputFPS)
            // 清理分段（可选：保留）
            job.update(status: .completed, progress: 1, message: "完成", output: outURL)
            persist(job)
            saveToPhotos(outURL, name: job.pkg.name + "_PipaRender")
        } catch {
            job.update(status: .failed, message: error.localizedDescription)
            persist(job)
        }
    }

    private func saveToPhotos(_ url: URL, name: String) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else { return }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .video, fileURL: url, options: nil)
            })
        }
    }
}
