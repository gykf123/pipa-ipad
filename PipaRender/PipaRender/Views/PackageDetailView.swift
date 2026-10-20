//
//  PackageDetailView.swift
//  PipaRender — 包详情：3D 预览 + 渲染参数 + 任务
//

import SwiftUI
import MetalKit
import Photos

struct PackageDetailView: View {
    let pkg: ImportedPackage
    @StateObject private var viewModel: DetailViewModel
    @State private var frameIndex: Float = 0
    @State private var outputFPS = 30
    @State private var occupancy: Float = 0.7
    @State private var useFullRange = true
    @State private var rangeStart: Float = 0
    @State private var rangeEnd: Float = 1
    @State private var includeAudio = true

    init(package: ImportedPackage) {
        self.pkg = package
        _viewModel = StateObject(wrappedValue: DetailViewModel(package: package))
    }

    var body: some View {
        Form {
            // 3D 预览
            Section(header: Text("预览（拖动旋转，双指缩放）").font(.caption)) {
                ZStack(alignment: .bottom) {
                    if let renderer = viewModel.previewRenderer {
                        MetalPreview(renderer: renderer, frameIndex: $frameIndex)
                            .frame(height: 300)
                            .cornerRadius(8)
                    } else if let err = viewModel.previewError {
                        Text(err).foregroundColor(.red).frame(height: 300)
                    } else {
                        ProgressView().frame(height: 300)
                    }
                    HStack {
                        Text("帧 \(Int(frameIndex) + 1)/\(pkg.pkg.frameCount)")
                            .font(.caption2).padding(6)
                            .background(.black.opacity(0.5)).foregroundColor(.white)
                            .cornerRadius(6)
                        Spacer()
                        Button(action: { viewModel.toggleCamera() }) {
                            Text(viewModel.usingPackageCamera ? "自由视角" : "原相机")
                                .font(.caption2).padding(6)
                                .background(.black.opacity(0.5)).foregroundColor(.white)
                                .cornerRadius(6)
                        }
                    }
                    .padding(8)
                }
                Slider(value: $frameIndex, in: 0...Float(max(pkg.pkg.frameCount - 1, 0)), step: 1)
            }

            // 渲染参数
            Section(header: Text("渲染参数").font(.caption)) {
                Picker("成品帧率", selection: $outputFPS) {
                    Text("24").tag(24); Text("30").tag(30); Text("60").tag(60)
                }
                VStack(alignment: .leading) {
                    Text("渲染最大占用：\(Int(occupancy * 100))%（影响内部分辨率 / SSAO / 阴影质量）")
                        .font(.subheadline)
                    Slider(value: $occupancy, in: 0.3...1.0, step: 0.05)
                }
                Toggle("全段渲染", isOn: $useFullRange)
                if !useFullRange {
                    HStack {
                        Text("起帧")
                        Spacer()
                        TextField("起", value: $rangeStart, format: .number)
                            .keyboardType(.numberPad).frame(width: 80).multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("止帧")
                        Spacer()
                        TextField("止", value: $rangeEnd, format: .number)
                            .keyboardType(.numberPad).frame(width: 80).multilineTextAlignment(.trailing)
                    }
                }
                Toggle("混入 BGM", isOn: $includeAudio).disabled(pkg.audioURL() == nil)
            }

            // 任务
            Section(header: Text("任务").font(.caption)) {
                Button(action: startJob) {
                    Label("开始渲染（分段可续）", systemImage: "play.fill")
                }
                .disabled(viewModel.jobs.contains { $0.status == .running })
                ForEach(viewModel.jobs) { job in
                    JobRow(job: job, onResume: { viewModel.resume(job) },
                           onDelete: { viewModel.delete(job) },
                           onSave: { viewModel.saveToPhotos(job) })
                }
            }
        }
        .navigationTitle(pkg.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            rangeEnd = Float(max(pkg.pkg.frameCount - 1, 0))
            frameIndex = 0
        }
    }

    private func startJob() {
        let n = pkg.pkg.frameCount
        let start = useFullRange ? 0 : Int(max(0, min(rangeStart, Float(n - 1))))
        let end = useFullRange ? n - 1 : Int(max(start, min(rangeEnd, Float(n - 1))))
        var s = RenderSettings()
        s.outputFPS = outputFPS
        s.occupancy = occupancy
        s.sourceStart = start
        s.sourceEnd = end
        s.includeAudio = includeAudio
        viewModel.startJob(settings: s)
    }
}

/// 单个任务行
struct JobRow: View {
    @ObservedObject var job: JobManager.RenderJob
    let onResume: () -> Void
    let onDelete: () -> Void
    let onSave: () -> Void
    @State private var showShare = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(statusText).font(.subheadline.bold())
                Spacer()
                Text("\(Int(job.progress * 100))%").font(.caption).foregroundColor(.secondary)
            }
            if job.status == .running || job.status == .pending {
                ProgressView(value: job.progress)
            }
            if !job.message.isEmpty {
                Text(job.message).font(.caption2).foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
                if job.status == .pending || job.status == .failed {
                    Button("续跑", action: onResume)
                }
                if job.status == .completed {
                    Button("存相册", action: onSave)
                    if job.outputURL != nil {
                        Button("分享") { showShare = true }
                    }
                }
                Spacer()
                Button("删除", role: .destructive, action: onDelete)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showShare) {
            if let url = job.outputURL {
                ActivityView(items: [url])
            }
        }
    }

    private var statusText: String {
        switch job.status {
        case .pending: return "待续跑"
        case .running: return "渲染中 · 段 \(job.segmentIndex + 1)/\(max(job.segments.count, 1))"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .canceled: return "已取消"
        }
    }
}

/// 详情页状态中枢（预览 renderer + 任务）
final class DetailViewModel: ObservableObject {
    @Published var previewRenderer: MetalRenderer?
    @Published var previewError: String?
    @Published var usingPackageCamera = true
    @Published private(set) var jobs: [JobManager.RenderJob] = []

    private let pkg: ImportedPackage

    init(package: ImportedPackage) {
        self.pkg = package
        jobs = JobManager.shared.jobs.filter { $0.pkg.id == package.id }
        buildPreview()
    }

    private func buildPreview() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let device = MTLCreateSystemDefaultDevice() else {
                DispatchQueue.main.async { self?.previewError = "Metal 不可用" }
                return
            }
            do {
                let assets = try SceneAssets(device: device, package: self.pkg)
                var s = RenderSettings()
                s.occupancy = 0.7
                s.sourceStart = 0
                s.sourceEnd = self.pkg.pkg.frameCount - 1
                let r = try MetalRenderer(device: device, assets: assets, settings: s)
                r.usePackageCamera = true
                DispatchQueue.main.async {
                    self.previewRenderer = r
                }
            } catch {
                DispatchQueue.main.async {
                    self.previewError = error.localizedDescription
                }
            }
        }
    }

    func toggleCamera() {
        guard let r = previewRenderer else { return }
        usingPackageCamera.toggle()
        r.usePackageCamera = usingPackageCamera
    }

    func startJob(settings: RenderSettings) {
        let job = JobManager.shared.createJob(pkg: pkg, settings: settings)
        jobs = JobManager.shared.jobs.filter { $0.pkg.id == pkg.id }
        JobManager.shared.start(job)
    }

    func resume(_ job: JobManager.RenderJob) {
        JobManager.shared.resume(job)
    }

    func delete(_ job: JobManager.RenderJob) {
        JobManager.shared.delete(job)
        jobs = JobManager.shared.jobs.filter { $0.pkg.id == pkg.id }
    }

    func saveToPhotos(_ job: JobManager.RenderJob) {
        guard let url = job.outputURL else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }
        }
    }
}
