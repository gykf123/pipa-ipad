//
//  SceneAssets.swift
//  PipaRender — 包 -> GPU 资源（网格 / 贴图 / pipeline / 粒子实例 / 碎块）
//
//  数据基准：GL（Y-up），由打包器烤入；本文件不做坐标转换，只负责上传与绑定。
//

import Metal
import MetalKit
import UIKit

enum RenderLimits {
    static let maxDebris = 96       // 3 事件 × 30 块 + 余量
}

// MARK: - 网格 GPU 数据

struct MeshGPU {
    let pos: MTLBuffer
    let nrm: MTLBuffer
    let uv: MTLBuffer
    let bi: MTLBuffer?      // 骨骼索引（f4×4）
    let bw: MTLBuffer?      // 骨骼权重（f4×4）
    let idx: MTLBuffer
    let indexCount: Int
    let vertexCount: Int
}

// MARK: - Pipeline 集合

struct RenderPipelines {
    // G-buffer：skinned × cut（albedo bgra8 / normal / viewpos / emit rgba16f + depth32）
    var gbufferPlain: MTLRenderPipelineState!
    var gbufferPlainCut: MTLRenderPipelineState!
    var gbufferSkinned: MTLRenderPipelineState!
    var gbufferSkinnedCut: MTLRenderPipelineState!
    // 阴影深度：skinned × cut（仅深度）
    var shadowPlain: MTLRenderPipelineState!
    var shadowPlainCut: MTLRenderPipelineState!
    var shadowSkinned: MTLRenderPipelineState!
    var shadowSkinnedCut: MTLRenderPipelineState!
    // 碎块（instanced model，非蒙皮）：cut × 0/1
    var debrisGBuffer: MTLRenderPipelineState!
    var debrisGBufferCut: MTLRenderPipelineState!
    var debrisShadow: MTLRenderPipelineState!
    var debrisShadowCut: MTLRenderPipelineState!
    // 全屏类
    var ssao: MTLRenderPipelineState!
    var blur: MTLRenderPipelineState!
    var lighting: MTLRenderPipelineState!
    var bright: MTLRenderPipelineState!
    var tonemap: MTLRenderPipelineState!
    // 粒子（加法混合，无深度）
    var tracer: MTLRenderPipelineState!
    var point: MTLRenderPipelineState!
}

// MARK: - 场景资源

final class SceneAssets {
    let device: MTLDevice
    let pkg: ImportedPackage

    var groupMeshes: [MeshGPU] = []          // 对齐 pkg.pkg.groups
    var partMeshes: [[MeshGPU]] = []         // [character][part]
    var movers: MTLBuffer?                   // 动态组逐帧矩阵
    var boneTracks: MTLBuffer?               // q4t3s3（char1 段 + char2 段拼接）
    var boneOffsets: [Int] = []              // 每角色在 bones.bin 的 float 偏移
    var cameraViews: MTLBuffer?
    var cameraMeta: MTLBuffer?
    var particles: MTLBuffer?
    var maxFrameParticles = 1
    var tracerInstances: MTLBuffer?          // 每帧填充
    var pointInstances: MTLBuffer?           // 每帧填充
    var debrisModels: MTLBuffer?             // 每帧填充（≤ RenderLimits.maxDebris）
    var aoKernel: MTLBuffer?
    var noiseTexture: MTLTexture?
    var debrisMesh: MeshGPU?
    var templateCornerQuad: MTLBuffer?       // 点精灵 6 顶点 corner（NDC ±1）
    var templateCornerStrip: MTLBuffer?      // 拖尾 6 顶点 corner（x=±1, y=0/1）

    var sceneTextures: [String: MTLTexture] = [:]
    var skinTextures: [String: MTLTexture] = [:]

    let sceneSampler: MTLSamplerState         // min/mip LINEAR, mag NEAREST, repeat
    let skinSampler: MTLSamplerState          // 全 NEAREST, clamp
    let screenSampler: MTLSamplerState        // clamp（屏幕空间 / G-buffer）
    let linearClampSampler: MTLSamplerState   // clamp + LINEAR（tonemap 上采样半分辨率 bloom）
    let noiseSampler: MTLSamplerState         // repeat + LINEAR（噪声旋转）

    var pipelines = RenderPipelines()
    let vertexDescriptor = MTLVertexDescriptor()          // 蒙皮（pos/nrm/uv/bi/bw）
    let plainVertexDescriptor = MTLVertexDescriptor()     // 非蒙皮（pos/nrm/uv）
    let particleDescriptor = MTLVertexDescriptor()

    /// 每帧活粒子数 / 活碎块数（drawInstanced 用，由 fillFrameData 更新）
    private(set) var activeTracerCount = 0
    private(set) var activePointCount = 0
    private(set) var activeDebrisCount = 0

    init(device: MTLDevice, package: ImportedPackage) throws {
        self.device = device
        self.pkg = package
        let p = package.pkg

        // ---- sampler ----
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.mipFilter = .linear; sd.magFilter = .nearest
        sd.sAddressMode = .repeat; sd.tAddressMode = .repeat
        sceneSampler = device.makeSamplerState(descriptor: sd)!

        let sk = MTLSamplerDescriptor()
        sk.minFilter = .nearest; sk.magFilter = .nearest
        sk.sAddressMode = .clampToEdge; sk.tAddressMode = .clampToEdge
        skinSampler = device.makeSamplerState(descriptor: sk)!

        let ss = MTLSamplerDescriptor()
        ss.minFilter = .nearest; ss.magFilter = .nearest
        ss.sAddressMode = .clampToEdge; ss.tAddressMode = .clampToEdge
        screenSampler = device.makeSamplerState(descriptor: ss)!

        let ns = MTLSamplerDescriptor()
        ns.minFilter = .linear; ns.magFilter = .linear
        ns.sAddressMode = .repeat; ns.tAddressMode = .repeat
        noiseSampler = device.makeSamplerState(descriptor: ns)!

        let lc = MTLSamplerDescriptor()
        lc.minFilter = .linear; lc.magFilter = .linear
        lc.sAddressMode = .clampToEdge; lc.tAddressMode = .clampToEdge
        linearClampSampler = device.makeSamplerState(descriptor: lc)!

        try buildVertexDescriptors()
        try buildMeshes()
        try buildStreams()
        try buildTextures()
        try buildAuxiliary()
        try buildPipelines()
    }

    // MARK: 顶点布局

    private func buildVertexDescriptors() throws {
        // 注意（Xcode 16 编译暴露）：
        // 1. MTLVertexAttributeDescriptor / MTLVertexBufferLayoutDescriptor 只有无参 init()，
        //    没有 (bufferIndex:offset:format:) 成员式构造——属性逐项赋值；
        // 2. ShaderTypes.h 的 C 枚举 rawValue 是 UInt32，attributes/layouts 下标要 Int。
        func setAttr(_ slot: UInt32, buffer: UInt32, format: MTLVertexFormat, offset: Int = 0) {
            let d = MTLVertexAttributeDescriptor()
            d.format = format
            d.offset = offset
            d.bufferIndex = Int(buffer)
            vertexDescriptor.attributes[Int(slot)] = d
        }
        func setLayout(_ buffer: UInt32, stride: Int) {
            let l = MTLVertexBufferLayoutDescriptor()
            l.stride = stride
            vertexDescriptor.layouts[Int(buffer)] = l
        }
        setAttr(VertexAttributePosition.rawValue, buffer: BufferIndexMeshPosition.rawValue, format: .float3)
        setAttr(VertexAttributeNormal.rawValue, buffer: BufferIndexMeshNormal.rawValue, format: .float3)
        setAttr(VertexAttributeUV.rawValue, buffer: BufferIndexMeshUV.rawValue, format: .float2)
        setAttr(VertexAttributeBoneIndex.rawValue, buffer: BufferIndexMeshBoneIndex.rawValue, format: .float4)
        setAttr(VertexAttributeBoneWeight.rawValue, buffer: BufferIndexMeshBoneWeight.rawValue, format: .float4)
        setLayout(BufferIndexMeshPosition.rawValue, stride: 12)
        setLayout(BufferIndexMeshNormal.rawValue, stride: 12)
        setLayout(BufferIndexMeshUV.rawValue, stride: 8)
        setLayout(BufferIndexMeshBoneIndex.rawValue, stride: 16)
        setLayout(BufferIndexMeshBoneWeight.rawValue, stride: 16)

        // 非蒙皮（静态组 / 碎块）：只绑 pos/nrm/uv，避免 Metal 验证缺失 bone buffer
        for attr in [VertexAttributePosition.rawValue, VertexAttributeNormal.rawValue, VertexAttributeUV.rawValue] {
            plainVertexDescriptor.attributes[Int(attr)] = vertexDescriptor.attributes[Int(attr)]
        }
        for l in [BufferIndexMeshPosition.rawValue, BufferIndexMeshNormal.rawValue, BufferIndexMeshUV.rawValue] {
            plainVertexDescriptor.layouts[Int(l)] = vertexDescriptor.layouts[Int(l)]
        }

        // 粒子：slot0 = 模板 corner（perVertex）；实例数据走 buffer(5) 直读（不进 vertex descriptor）
        setAttr(VertexAttributeCorner.rawValue, buffer: 0, format: .float2)
        setLayout(0, stride: 8)
    }

    // MARK: 网格

    private func buildMeshes() throws {
        let p = pkg.pkg
        groupMeshes = try p.groups.map {
            try buildMesh(bufs: $0.buf, file: $0.buf["pos"]?.file ?? "meshes.bin")
        }
        var boneOff: [Int] = []
        var running = 0
        for c in p.characters {
            // 显式 offset 优先；缺省按 characters 顺序累加（兼容无 offset 字段的旧包）
            boneOff.append(c.boneBuffer.offset ?? running)
            running += c.boneBuffer.frames * c.boneBuffer.bones * 10
            partMeshes.append(try c.parts.map {
                try buildMesh(bufs: $0.buf, file: $0.buf["pos"]?.file ?? "meshes.bin")
            })
        }
        boneOffsets = boneOff
    }

    private func buildMesh(bufs: [String: BufferRef], file: String) throws -> MeshGPU {
        let data = try pkg.blob(file)
        func buf(_ name: String) -> MTLBuffer {
            let r = bufs[name]!
            let bytes = r.count * 4
            let ptr = data.withUnsafeBytes { $0.baseAddress!.advanced(by: r.offset) }
            return device.makeBuffer(bytes: ptr, length: bytes, options: .storageModeShared)!
        }
        let idxCount = bufs["idx"]!.count
        let posR = bufs["pos"]!
        return MeshGPU(
            pos: buf("pos"), nrm: buf("nrm"), uv: buf("uv"),
            bi: bufs["bi"] != nil ? buf("bi") : nil,
            bw: bufs["bw"] != nil ? buf("bw") : nil,
            idx: buf("idx"),
            indexCount: idxCount,
            vertexCount: posR.count / 3)
    }

    // MARK: 逐帧流（movers / bones / camera / particles）

    private func buildStreams() throws {
        let p = pkg.pkg
        if pkg.exists("movers.bin") {
            let mb = try pkg.blob("movers.bin")
            movers = device.makeBuffer(bytes: mb.withUnsafeBytes { $0.baseAddress! }, length: mb.count,
                                       options: .storageModeShared)!
        }
        let bb = try pkg.blob("bones.bin")
        boneTracks = device.makeBuffer(bytes: bb.withUnsafeBytes { $0.baseAddress! }, length: bb.count,
                                       options: .storageModeShared)!
        let cb = try pkg.blob(p.camera.buffer)
        cameraViews = device.makeBuffer(bytes: cb.withUnsafeBytes { $0.baseAddress! }, length: cb.count,
                                        options: .storageModeShared)!
        if let mb = p.camera.metaBuffer, pkg.exists(mb) {
            let cm = try pkg.blob(mb)
            cameraMeta = device.makeBuffer(bytes: cm.withUnsafeBytes { $0.baseAddress! }, length: cm.count,
                                           options: .storageModeShared)!
        }
        let pb = try pkg.blob(p.particles.buffer)
        particles = device.makeBuffer(bytes: pb.withUnsafeBytes { $0.baseAddress! }, length: pb.count,
                                      options: .storageModeShared)!
        // 每帧粒子数峰值
        let off = try pkg.uint32s(p.particles.buffer, byteOffset: p.particles.off.offset, count: p.particles.off.count)
        for i in 0..<max(off.count - 1, 0) {
            let n = Int(off[i + 1]) - Int(off[i])
            if n > maxFrameParticles { maxFrameParticles = n }
        }
        maxFrameParticles = max(maxFrameParticles, 1)
        tracerInstances = device.makeBuffer(length: maxFrameParticles * 9 * 4, options: .storageModeShared)
        pointInstances = device.makeBuffer(length: maxFrameParticles * 7 * 4, options: .storageModeShared)
        debrisModels = device.makeBuffer(length: RenderLimits.maxDebris * 64, options: .storageModeShared)
    }

    // MARK: 贴图

    private func buildTextures() throws {
        let loader = MTKTextureLoader(device: device)
        var texOpts: [MTKTextureLoader.Option: Any] = [
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .generateMipmaps: NSNumber(value: true),
            .SRGB: NSNumber(value: false),      // 保持 sRGB 存储值，shader 内 pow(2.2) 线性化（复刻桌面端）
        ]
        for g in pkg.pkg.groups {
            if let t = g.texture, sceneTextures[t] == nil, pkg.exists(t) {
                let img = try pkg.loadTextureImage(t)
                sceneTextures[t] = try loader.newTexture(cgImage: img.cgImage!, options: texOpts)
            }
        }
        texOpts[.generateMipmaps] = NSNumber(value: false)   // 皮肤 NEAREST，无需 mip
        for c in pkg.pkg.characters {
            if let s = c.skin, skinTextures[s] == nil, pkg.exists(s) {
                let img = try pkg.loadTextureImage(s)
                skinTextures[s] = try loader.newTexture(cgImage: img.cgImage!, options: texOpts)
            }
        }
    }

    // MARK: AO / 噪声 / 碎块网格 / 粒子模板

    private func buildAuxiliary() throws {
        let p = pkg.pkg
        if let ao = p.ao, pkg.exists(ao.buffer) {
            let d = try pkg.blob(ao.buffer)
            let kc = ao.kernelCount
            aoKernel = device.makeBuffer(bytes: d.withUnsafeBytes { $0.baseAddress! }, length: kc * 3 * 4,
                                         options: .storageModeShared)
            let noisePtr = d.withUnsafeBytes { $0.baseAddress!.advanced(by: kc * 3 * 4) }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: ao.noiseSize,
                                                                height: ao.noiseSize, mipmapped: false)
            desc.usage = .shaderRead
            let tex = device.makeTexture(descriptor: desc)!
            tex.replace(region: MTLRegionMake2D(0, 0, ao.noiseSize, ao.noiseSize), mipmapLevel: 0,
                        withBytes: noisePtr, bytesPerRow: ao.noiseSize * 16)
            noiseTexture = tex
        }
        debrisMesh = Self.makeCube(device: device)
        let quad: [Float] = [-1, -1, 1, -1, -1, 1, 1, -1, 1, 1, -1, 1]
        templateCornerQuad = device.makeBuffer(bytes: quad, length: quad.count * 4, options: .storageModeShared)
        let strip: [Float] = [-1, 0, 1, 0, -1, 1, 1, 0, 1, 1, -1, 1]
        templateCornerStrip = device.makeBuffer(bytes: strip, length: strip.count * 4, options: .storageModeShared)
    }

    /// 碎块单位立方体（24 顶点，每面独立法线）
    static func makeCube(device: MTLDevice) -> MeshGPU {
        var pos: [Float] = [], nrm: [Float] = [], uv: [Float] = []
        let faces: [(simd_float3, simd_float3, simd_float3)] = [
            (simd_float3(0, 0, 1), simd_float3(1, 0, 0), simd_float3(0, 1, 0)),
            (simd_float3(0, 0, -1), simd_float3(0, 1, 0), simd_float3(1, 0, 0)),
            (simd_float3(1, 0, 0), simd_float3(0, 1, 0), simd_float3(0, 0, -1)),
            (simd_float3(-1, 0, 0), simd_float3(0, 0, 1), simd_float3(0, 1, 0)),
            (simd_float3(0, 1, 0), simd_float3(1, 0, 0), simd_float3(0, 0, -1)),
            (simd_float3(0, -1, 0), simd_float3(0, 0, 1), simd_float3(1, 0, 0)),
        ]
        for (n, u, v) in faces {
            let corners = [simd_float3(-0.5, -0.5, 0), simd_float3(0.5, -0.5, 0), simd_float3(-0.5, 0.5, 0), simd_float3(0.5, 0.5, 0)]
            let uvs: [simd_float2] = [simd_float2(0, 0), simd_float2(1, 0), simd_float2(0, 1), simd_float2(1, 1)]
            for i in 0..<4 {
                let pp = corners[i].x * u + corners[i].y * v + n * 0.5
                pos += [pp.x, pp.y, pp.z]; nrm += [n.x, n.y, n.z]; uv += [uvs[i].x, uvs[i].y]
            }
        }
        var idx: [UInt32] = []
        for f in 0..<6 {
            let b = UInt32(f * 4)
            idx += [b, b + 1, b + 2, b + 1, b + 3, b + 2]
        }
        return MeshGPU(
            pos: device.makeBuffer(bytes: pos, length: pos.count * 4, options: .storageModeShared)!,
            nrm: device.makeBuffer(bytes: nrm, length: nrm.count * 4, options: .storageModeShared)!,
            uv: device.makeBuffer(bytes: uv, length: uv.count * 4, options: .storageModeShared)!,
            bi: nil, bw: nil,
            idx: device.makeBuffer(bytes: idx, length: idx.count * 4, options: .storageModeShared)!,
            indexCount: idx.count, vertexCount: 24)
    }

    // MARK: Pipeline

    private func buildPipelines() throws {
        guard let lib = device.makeDefaultLibrary() else {
            throw PackageError.metalFailure("默认 Metal 库不可用")
        }
        func fn(_ name: String, constants: MTLFunctionConstantValues? = nil) throws -> MTLFunction {
            if let c = constants {
                return try lib.makeFunction(name: name, constantValues: c)
            }
            guard let f = lib.makeFunction(name: name) else {
                throw PackageError.metalFailure("缺少函数 \(name)")
            }
            return f
        }
        // function_constant 索引 = metal 中声明顺序（skinned=0, useInstanceModel=1）
        func constants(skinned: Bool, instanced: Bool) -> MTLFunctionConstantValues {
            let c = MTLFunctionConstantValues()
            var s = skinned, i = instanced        // setConstantValue 要 inout，形参是 let
            c.setConstantValue(&s, type: .bool, index: 0)
            c.setConstantValue(&i, type: .bool, index: 1)
            return c
        }

        func meshPipeline(fragment: String, skinned: Bool, instanced: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexDescriptor = skinned ? vertexDescriptor : plainVertexDescriptor
            d.vertexFunction = try fn("mesh_vertex", constants: constants(skinned: skinned, instanced: instanced))
            d.fragmentFunction = try fn(fragment)
            if fragment.hasPrefix("shadow") {
                d.colorAttachments[0].pixelFormat = .invalid      // 仅深度
            } else {
                d.colorAttachments[0].pixelFormat = .bgra8Unorm   // albedo
                d.colorAttachments[1].pixelFormat = .rgba16Float  // normal
                d.colorAttachments[2].pixelFormat = .rgba16Float  // viewpos
                d.colorAttachments[3].pixelFormat = .rgba16Float  // emit
            }
            d.depthAttachmentPixelFormat = .depth32Float
            d.stencilAttachmentPixelFormat = .invalid
            return try device.makeRenderPipelineState(descriptor: d)
        }
        func screenPipeline(fragment: String, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try fn("fullscreen_vertex")
            d.fragmentFunction = try fn(fragment)
            d.colorAttachments[0].pixelFormat = pixelFormat
            d.stencilAttachmentPixelFormat = .invalid
            return try device.makeRenderPipelineState(descriptor: d)
        }

        pipelines.gbufferPlain = try meshPipeline(fragment: "mesh_fragment", skinned: false, instanced: false)
        pipelines.gbufferPlainCut = try meshPipeline(fragment: "mesh_fragment_cut", skinned: false, instanced: false)
        pipelines.gbufferSkinned = try meshPipeline(fragment: "mesh_fragment", skinned: true, instanced: false)
        pipelines.gbufferSkinnedCut = try meshPipeline(fragment: "mesh_fragment_cut", skinned: true, instanced: false)
        pipelines.shadowPlain = try meshPipeline(fragment: "shadow_fragment", skinned: false, instanced: false)
        pipelines.shadowPlainCut = try meshPipeline(fragment: "shadow_fragment_cut", skinned: false, instanced: false)
        pipelines.shadowSkinned = try meshPipeline(fragment: "shadow_fragment", skinned: true, instanced: false)
        pipelines.shadowSkinnedCut = try meshPipeline(fragment: "shadow_fragment_cut", skinned: true, instanced: false)
        pipelines.debrisGBuffer = try meshPipeline(fragment: "mesh_fragment", skinned: false, instanced: true)
        pipelines.debrisGBufferCut = try meshPipeline(fragment: "mesh_fragment_cut", skinned: false, instanced: true)
        pipelines.debrisShadow = try meshPipeline(fragment: "shadow_fragment", skinned: false, instanced: true)
        pipelines.debrisShadowCut = try meshPipeline(fragment: "shadow_fragment_cut", skinned: false, instanced: true)

        pipelines.ssao = try screenPipeline(fragment: "ssao_fragment", pixelFormat: .rgba16Float)
        pipelines.blur = try screenPipeline(fragment: "blur_fragment", pixelFormat: .rgba16Float)
        pipelines.lighting = try screenPipeline(fragment: "lighting_fragment", pixelFormat: .rgba16Float)
        pipelines.bright = try screenPipeline(fragment: "bright_fragment", pixelFormat: .rgba16Float)
        pipelines.tonemap = try screenPipeline(fragment: "tonemap_fragment", pixelFormat: .bgra8Unorm)

        // 粒子：加法混合、无深度附件
        func particlePipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexDescriptor = particleDescriptor
            d.vertexFunction = try fn(vertex)
            d.fragmentFunction = try fn(fragment)
            // colorAttachments 下标返回 IUO：直接成员赋值可隐式解包；
            // 先 let 绑定会丢掉 IUO 性（变成 T?），成员访问必须显式解包——故用直接赋值。
            d.colorAttachments[0].pixelFormat = .rgba16Float
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].rgbBlendOperation = .add
            d.colorAttachments[0].sourceRGBBlendFactor = .one
            d.colorAttachments[0].destinationRGBBlendFactor = .one
            d.colorAttachments[0].alphaBlendOperation = .add
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .one
            d.depthAttachmentPixelFormat = .invalid
            d.stencilAttachmentPixelFormat = .invalid
            return try device.makeRenderPipelineState(descriptor: d)
        }
        pipelines.tracer = try particlePipeline(vertex: "tracer_vertex", fragment: "tracer_fragment")
        pipelines.point = try particlePipeline(vertex: "point_vertex", fragment: "point_fragment")
    }

    // MARK: 每帧数据填充

    /// 按源帧索引（0 基，相对 frame_start）填充粒子实例与活碎块模型矩阵
    func fillFrameData(frameIndex: Int, shutter: Float,
                       debrisEvents: [DebrisEvent], debrisData: Data?, debrisDefaults: DebrisDefaults,
                       fps: Float) {
        // ---- 粒子 ----
        let p = pkg.pkg.particles
        let pb = try! pkg.blob(p.buffer)
        let offCount = p.off.count
        let offPtr = pb.withUnsafeBytes { $0.bindMemory(to: UInt32.self).baseAddress!.advanced(by: p.off.offset / 4) }
        let fi = max(0, min(frameIndex, offCount - 2))
        let first = Int(offPtr[fi]), last = Int(offPtr[fi + 1])
        let n = max(0, last - first)
        if n > 0 {
            let posPtr = pb.withUnsafeBytes { $0.bindMemory(to: Float.self).baseAddress!.advanced(by: p.pos.offset / 4) + first * 3 }
            let emPtr = pb.withUnsafeBytes { $0.bindMemory(to: Float.self).baseAddress!.advanced(by: p.em.offset / 4) + first * 3 }
            let velPtr = pb.withUnsafeBytes { $0.bindMemory(to: Float.self).baseAddress!.advanced(by: p.vel.offset / 4) + first * 3 }
            let sizePtr = pb.withUnsafeBytes { $0.bindMemory(to: Float.self).baseAddress!.advanced(by: p.size.offset / 4) + first }
            let half = shutter * 0.5
            let tp = tracerInstances!.contents().assumingMemoryBound(to: Float.self)
            let pp = pointInstances!.contents().assumingMemoryBound(to: Float.self)
            for i in 0..<n {
                let px = posPtr[i * 3], py = posPtr[i * 3 + 1], pz = posPtr[i * 3 + 2]
                let vx = velPtr[i * 3] * half, vy = velPtr[i * 3 + 1] * half, vz = velPtr[i * 3 + 2] * half
                let er = emPtr[i * 3], eg = emPtr[i * 3 + 1], eb = emPtr[i * 3 + 2]
                tp[i * 9 + 0] = px; tp[i * 9 + 1] = py; tp[i * 9 + 2] = pz
                tp[i * 9 + 3] = vx; tp[i * 9 + 4] = vy; tp[i * 9 + 5] = vz
                tp[i * 9 + 6] = er; tp[i * 9 + 7] = eg; tp[i * 9 + 8] = eb
                pp[i * 7 + 0] = px; pp[i * 7 + 1] = py; pp[i * 7 + 2] = pz
                pp[i * 7 + 3] = sizePtr[i]
                pp[i * 7 + 4] = er; pp[i * 7 + 5] = eg; pp[i * 7 + 6] = eb
            }
        }
        activeTracerCount = n
        activePointCount = n

        // ---- 碎块 ----
        activeDebrisCount = 0
        guard !debrisEvents.isEmpty, let ddata = debrisData else { return }
        let srcFrame = Float(frameIndex) + Float(pkg.pkg.frameStart)
        let mptr = debrisModels!.contents().assumingMemoryBound(to: Float.self)
        var count = 0
        for ev in debrisEvents {
            let t = (srcFrame - ev.frame) / max(fps, 1)
            if t < 0 || t > debrisDefaults.life || count + ev.count > RenderLimits.maxDebris { continue }
            let base = ev.offset / 4 + 4          // 16 字节头（4 floats）之后
            let dptr = ddata.withUnsafeBytes { $0.bindMemory(to: Float.self).baseAddress! }
            let fade: Float = t < 0.72 * debrisDefaults.life ? 1 : max((1 - t / debrisDefaults.life) / 0.28, 0)
            let g = debrisDefaults.gravity
            for k in 0..<ev.count {
                let o = base + k * 11
                let p0 = simd_float3(dptr[o], dptr[o + 1], dptr[o + 2])
                let v0 = simd_float3(dptr[o + 3], dptr[o + 4], dptr[o + 5])
                let axis = simd_float3(dptr[o + 6], dptr[o + 7], dptr[o + 8])
                let ang = dptr[o + 9], size = dptr[o + 10]
                var pos = p0 + v0 * t
                pos.y += 0.5 * g * t * t
                pos.y = max(pos.y, ev.floor)
                var m = simd_float4x4(translation: pos) * simd_float4x4(simd_quatf(angle: ang * t, axis: axis))
                m = m * simd_float4x4(scale: simd_float3(repeating: size * fade))
                withUnsafePointer(to: &m) { mp in
                    memcpy(UnsafeMutableRawPointer(mptr.advanced(by: count * 16)), mp, 64)
                }
                count += 1
            }
        }
        activeDebrisCount = count
    }
}
