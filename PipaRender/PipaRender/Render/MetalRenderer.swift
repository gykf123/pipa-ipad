//
//  MetalRenderer.swift
//  PipaRender — 渲染管线编排（CSM 阴影 -> G-buffer -> SSAO -> 光照 -> 粒子 -> 泛光/辉光 -> tonemap）
//
//  逐 pass 复刻桌面端 renderer.pyc 的顺序与公式；数据全部 GL 基准（打包器烤入）。
//

import Metal
import MetalKit
import CoreVideo
import UIKit

final class MetalRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let assets: SceneAssets
    let pkg: ImportedPackage
    var settings: RenderSettings {
        didSet { rebuildTargetsIfNeeded() }
    }
    private var quality: QualityProfile

    // 渲染目标（内部分辨率）
    private var internalW = 1, internalH = 1
    private var outW = 1, outH = 1
    private var albedoTex: MTLTexture!
    private var normalTex: MTLTexture!
    private var viewposTex: MTLTexture!
    private var emitTex: MTLTexture!
    private var depthTex: MTLTexture!
    private var shadowTex: [MTLTexture] = []
    private var aoTexA: MTLTexture!
    private var aoTexB: MTLTexture!
    private var hdrTex: MTLTexture!
    private var glareA: MTLTexture!
    private var glareB: MTLTexture!
    private var bloomA: MTLTexture!
    private var bloomB: MTLTexture!

    // 每帧/每 draw GPU 数据
    private var uniformBuffer: MTLBuffer!
    private var lightsBuffer: MTLBuffer!
    private var bonesBuffers: [MTLBuffer] = []
    private var textureCache: CVMetalTextureCache?

    // 包数据
    private var visibility: VisibilityBitmap?
    private var debrisEvents: [DebrisEvent] = []
    private var debrisData: Data?
    private var animatedGroupIndices: [Int] = []     // groups 中 animated 的下标
    private var identity = matrix_identity_float4x4

    // 预览相机（自由轨道）；usePackageCamera=true 时用包内相机轨迹
    var usePackageCamera = true
    var previewYaw: Float = 0.9
    var previewPitch: Float = 0.32
    var previewDist: Float = 15
    var previewTarget = simd_float3(0, 5, -10)

    init(device: MTLDevice, assets: SceneAssets, settings: RenderSettings) throws {
        self.device = device
        self.assets = assets
        self.pkg = assets.pkg
        self.settings = settings
        self.quality = QualityProfile.profile(occupancy: settings.occupancy)

        guard let q = device.makeCommandQueue() else { throw PackageError.metalFailure("CommandQueue 创建失败") }
        queue = q

        let p = pkg.pkg
        // 灯光（静态，一次上传）
        // 注意：MAX_LIGHTS/MAX_BONES 是 C #define，Swift 导入为 Int32——与 Int 运算前先转
        let nLights = min(p.lights.count, Int(MAX_LIGHTS))
        lightsBuffer = device.makeBuffer(length: max(nLights, 1) * MemoryLayout<LightData>.stride,
                                         options: .storageModeShared)
        var ldata: [LightData] = []
        for l in p.lights.prefix(Int(MAX_LIGHTS)) {
            let isArea: Float = (l.type == "AREA") ? 1 : 0
            let nrm = l.normal ?? [0, 0, 0]
            ldata.append(LightData(pos: simd_float4(l.pos[0], l.pos[1], l.pos[2], 0),
                                   col: simd_float4(l.color[0], l.color[1], l.color[2], 1),
                                   dir: simd_float4(nrm[0], nrm[1], nrm[2], isArea),
                                   energy: simd_float4(l.energy, 0, 0, 0)))
        }
        if !ldata.isEmpty {
            lightsBuffer.contents().copyMemory(from: ldata, byteCount: ldata.count * MemoryLayout<LightData>.stride)
        }

        // 骨骼矩阵 buffer（每角色一个）
        for c in p.characters {
            guard c.boneCount <= MAX_BONES else {
                throw PackageError.corruptData("角色 \(c.name) 骨骼数 \(c.boneCount) 超过上限 \(MAX_BONES)")
            }
            bonesBuffers.append(device.makeBuffer(length: Int(MAX_BONES) * 64, options: .storageModeShared)!)
        }

        // 可见性 / 碎块
        if let vi = p.visibility, let d = try? pkg.blob(vi.buffer) {
            visibility = VisibilityBitmap(data: d, groups: vi.groups, frames: vi.frames)
        }
        if let di = p.debris, let d = try? pkg.blob(di.buffer) {
            debrisData = d
            debrisEvents = di.events
        }
        for (i, g) in p.groups.enumerated() where g.animated {
            animatedGroupIndices.append(i)
        }

        uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)!
        // CVMetalTextureCacheCreate(allocator, cacheAttributes, metalDevice, textureAttributes, out)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        rebuildTargetsIfNeeded()
    }

    // MARK: - 目标分配

    private func rebuildTargetsIfNeeded() {
        let q = QualityProfile.profile(occupancy: settings.occupancy)
        let w = max(8, Int(Float(pkg.pkg.width) * q.scale / 8) * 8)
        let h = max(8, Int(Float(pkg.pkg.height) * q.scale / 8) * 8)
        let changed = (w != internalW || h != internalH || q.scale != quality.scale)
        quality = q
        if changed {
            internalW = w; internalH = h
            allocateTargets()
        }
        if outW < 8 || outH < 8 { outW = internalW; outH = internalH }
    }

    private func allocateTargets() {
        func tex(_ format: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage = [.renderTarget, .shaderRead]) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(w, 1), height: max(h, 1), mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        albedoTex = tex(.bgra8Unorm, internalW, internalH)
        normalTex = tex(.rgba16Float, internalW, internalH)
        viewposTex = tex(.rgba16Float, internalW, internalH)
        emitTex = tex(.rgba16Float, internalW, internalH)
        depthTex = tex(.depth32Float, internalW, internalH)
        aoTexA = tex(.rgba16Float, internalW, internalH)
        aoTexB = tex(.rgba16Float, internalW, internalH)
        hdrTex = tex(.rgba16Float, internalW, internalH)
        glareA = tex(.rgba16Float, internalW, internalH)
        glareB = tex(.rgba16Float, internalW, internalH)
        bloomA = tex(.rgba16Float, internalW / 2, internalH / 2)
        bloomB = tex(.rgba16Float, internalW / 2, internalH / 2)
        shadowTex = (0..<3).map { _ in tex(.depth32Float, quality.shadowMapSize, quality.shadowMapSize) }
    }

    /// 预览 drawable 尺寸变化（只影响投影宽高比；渲染目标按内部尺寸）
    func setOutputSize(w: Int, h: Int) {
        outW = max(2, min(w, 2560)); outH = max(2, min(h, 2560))
    }

    // MARK: - 每帧数据

    private struct FrameData {
        var view = matrix_identity_float4x4
        var proj = matrix_identity_float4x4
        var near: Float = 0.1
        var far: Float = 200
        var visibleGroups: [Int] = []
        var frameMats: [Int: simd_float4x4] = [:]
        var cascade: [(view: simd_float4x4, proj: simd_float4x4)] = []
        var splits: simd_float3 = .zero
    }

    /// 每帧 CPU 侧准备：相机、可见集合、级联、骨骼、粒子、碎块
    private func prepareFrame(sourceFrame: Float) -> FrameData {
        let p = pkg.pkg
        let fi = max(0, min(Int(floor(sourceFrame)), p.frameCount - 1))
        var fd = FrameData()

        // 相机
        var fov: Float = 55
        var near: Float = 0.1
        var far: Float = 400
        if let mb = p.camera.metaBuffer,
           let meta = try? pkg.floats(mb, byteOffset: fi * 16, count: 4), meta.count == 4 {
            fov = meta[0]
            near = max(meta[1], 0.02)
            far = min(max(meta[2], near + 1), 600)
        }
        fd.near = near; fd.far = far

        if usePackageCamera,
           let vm = try? pkg.floats(p.camera.buffer, byteOffset: fi * 64, count: 16), vm.count == 16 {
            fd.view = simd_float4x4(rowMajor: vm)
        } else {
            let eye = previewTarget + simd_float3(cosf(previewYaw) * cosf(previewPitch),
                                                  sinf(previewPitch),
                                                  sinf(previewYaw) * cosf(previewPitch)) * previewDist
            fd.view = simd_float4x4.lookAt(eye: eye, center: previewTarget, up: simd_float3(0, 1, 0))
        }
        fd.proj = simd_float4x4.perspective(fovYDegrees: usePackageCamera ? fov : 55,
                                            aspect: Float(outW) / Float(outH), near: near, far: far)

        // 级联阴影
        let d = p.defaults
        let total = min(d.shadowDistance, far * 0.95)
        fd.splits = simd_float3(total * 0.18, total * 0.45, total)
        fd.cascade = cascadeMatrices(view: fd.view, proj: fd.proj,
                                     sunDir: normalize(simd_float3(p.sun.dir[0], p.sun.dir[1], p.sun.dir[2])),
                                     splits: fd.splits, near: near)

        // 可见集合：可见性位图 + 视锥剔除
        let frustum = Frustum(viewProj: fd.proj * fd.view)
        var vis: [Int] = []
        vis.reserveCapacity(p.groups.count)
        for (i, g) in p.groups.enumerated() {
            if let v = visibility, !v.isVisible(frame: fi, group: i) { continue }
            var lo = simd_float3(g.bounds.min[0], g.bounds.min[1], g.bounds.min[2])
            var hi = simd_float3(g.bounds.max[0], g.bounds.max[1], g.bounds.max[2])
            if g.animated, let mat = moversMatrix(frame: fi, group: i) {
                fd.frameMats[i] = mat
                var nlo = simd_float3(repeating: .greatestFiniteMagnitude)
                var nhi = simd_float3(repeating: -.greatestFiniteMagnitude)
                for cx in [lo.x, hi.x] {
                    for cy in [lo.y, hi.y] {
                        for cz in [lo.z, hi.z] {
                            let w = mat * simd_float4(cx, cy, cz, 1)
                            let q = simd_float3(w.x, w.y, w.z)
                            nlo = min(nlo, q); nhi = max(nhi, q)
                        }
                    }
                }
                lo = nlo; hi = nhi
            }
            if frustum.intersects(min: lo, max: hi) { vis.append(i) }
        }
        fd.visibleGroups = vis

        // 骨骼矩阵（每角色）：JIT 内核优先，自动降级 Skinner.swift
        let track = try? pkg.blob("bones.bin")
        if let track = track {
            for (ci, c) in p.characters.enumerated() {
                let dst = bonesBuffers[ci].contents()
                SkinKernel.matrices(track: track, charOffsetFloats: assets.boneOffsets[ci],
                                    frames: c.boneBuffer.frames, boneCount: c.boneCount,
                                    frameStart: p.frameStart, frame: Float(fi),
                                    armatureWorld: simd_float4x4(rowMajor: c.armatureWorld),
                                    into: dst)
            }
        }

        // 粒子 + 碎块
        assets.fillFrameData(frameIndex: fi, shutter: p.shutter, debrisEvents: debrisEvents,
                             debrisData: debrisData, debrisDefaults: p.defaults.debris, fps: Float(p.fps))
        return fd
    }

    /// 动态组当前帧矩阵（movers.bin 布局：按 groups 顺序拼接的 [frames][16]）
    private func moversMatrix(frame fi: Int, group gi: Int) -> simd_float4x4? {
        guard let buf = assets.movers, let g = pkg.pkg.groups[gi].mat else { return nil }
        // bindMemory(to:capacity:) 才返回可用指针； typed 指针没有 baseAddress 成员
        let ptr = buf.contents().bindMemory(to: Float.self, capacity: buf.length / MemoryLayout<Float>.stride)
        let base = ptr.advanced(by: (g.offset / 4) + fi * 16)
        return simd_float4x4(rowMajor: Array(UnsafeBufferPointer(start: base, count: 16)))
    }

    // MARK: - Uniform 更新

    private func writeUniforms(_ u: UnsafeMutablePointer<Uniforms>) {
        memcpy(uniformBuffer.contents(), u, MemoryLayout<Uniforms>.stride)
    }

    private func baseUniforms(fd: FrameData) -> Uniforms {
        var u = Uniforms()
        let p = pkg.pkg
        let d = p.defaults
        u.view = fd.view
        u.proj = fd.proj
        u.invView = fd.view.inverse
        u.lightDir = simd_float4(normalize(simd_float3(p.sun.dir[0], p.sun.dir[1], p.sun.dir[2])), 0)
        u.lightColor = simd_float4(p.sun.color[0], p.sun.color[1], p.sun.color[2], p.sun.intensity)
        u.skyColor = simd_float4(d.skyColor[0], d.skyColor[1], d.skyColor[2], 1)
        u.groundColor = simd_float4(d.groundColor[0], d.groundColor[1], d.groundColor[2], 1)
        u.ambient = simd_float4(d.ambientIntensity, 0, 0, 0)
        u.specRough = simd_float4(d.specStrength, d.roughness, 0, 0)
        u.shadowParams = simd_float4(d.shadowSoftness, 1.0 / Float(quality.shadowMapSize),
                                     Float(quality.shadowSamples), (d.shadow && quality.shadowSamples > 0) ? 1 : 0)
        u.splits = simd_float4(fd.splits.x, fd.splits.y, fd.splits.z, 0)
        u.aoParams = simd_float4(d.aoRadius, 0.025, d.aoIntensity, d.ao ? 1 : 0)
        u.pointParams = simd_float4(d.pointScale, d.pointSoft, 0, 0)
        u.exposureGamma = simd_float4(d.exposure, d.gamma, 0, 0)
        let tmMode: Float = d.tonemap == "aces" ? 1 : (d.tonemap == "standard" ? 2 : 0)
        u.tonemapMode = simd_float4(tmMode, quality.bloom && d.bloom ? 1 : 0,
                                    quality.glare && d.glare ? 1 : 0, d.bloomStrength)
        u.glareStrength = simd_float4(d.glareStrength, 0, 0, 0)
        u.bloomThreshold = simd_float4(d.bloomThreshold, 0, 0, 0)
        u.glareThreshold = simd_float4(d.glareThreshold, d.glareSmoothness, 0, 0)
        u.screen = simd_float4(Float(internalW), Float(internalH), 1.0 / Float(internalW), 1.0 / Float(internalH))
        u.particleParams = simd_float4(d.particleWidth, d.particleScale, d.particleStreak, 0)
        u.numLights = simd_float4(Float(min(p.lights.count, Int(MAX_LIGHTS))), Float(quality.aoSamples), 0, 0)
        u.flipMode = simd_float4(0, 0, 0, 0)
        return u
    }

    // MARK: - 公共渲染入口

    func render(sourceFrame: Float, to drawable: CAMetalDrawable) {
        renderFrame(sourceFrame: sourceFrame, targetTexture: drawable.texture, targetW: drawable.texture.width,
                    targetH: drawable.texture.height, flip: false)
    }

    func render(sourceFrame: Float, to pixelBuffer: CVPixelBuffer) throws {
        guard let cache = textureCache else { throw PackageError.metalFailure("CVMetalTextureCache 不可用") }
        var cvOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm,
                                                               CVPixelBufferGetWidth(pixelBuffer),
                                                               CVPixelBufferGetHeight(pixelBuffer), 0, &cvOut)
        guard status == kCVReturnSuccess, let tex = CVMetalTextureGetTexture(cvOut!) else {
            throw PackageError.metalFailure("CVPixelBuffer -> Metal 纹理失败 (\(status))")
        }
        renderFrame(sourceFrame: sourceFrame, targetTexture: tex,
                    targetW: tex.width, targetH: tex.height, flip: true)
    }

    // MARK: - 主流程

    private func renderFrame(sourceFrame: Float, targetTexture: MTLTexture, targetW: Int, targetH: Int, flip: Bool) {
        let fd = prepareFrame(sourceFrame: sourceFrame)
        guard let cb = queue.makeCommandBuffer() else { return }
        encodeAll(commandBuffer: cb, fd: fd, target: targetTexture, targetW: targetW, targetH: targetH, flip: flip)
        cb.commit()
    }

    /// 视频导出用：渲染并等待完成（保证 CVPixelBuffer 可安全复用）
    func renderAndWait(sourceFrame: Float, pixelBuffer: CVPixelBuffer) throws {
        guard let cache = textureCache else { throw PackageError.metalFailure("CVMetalTextureCache 不可用") }
        var cvOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm,
                                                               CVPixelBufferGetWidth(pixelBuffer),
                                                               CVPixelBufferGetHeight(pixelBuffer), 0, &cvOut)
        guard status == kCVReturnSuccess, let tex = CVMetalTextureGetTexture(cvOut!) else {
            throw PackageError.metalFailure("CVPixelBuffer -> Metal 纹理失败")
        }
        let fd = prepareFrame(sourceFrame: sourceFrame)
        guard let cb = queue.makeCommandBuffer() else { return }
        encodeAll(commandBuffer: cb, fd: fd, target: tex, targetW: tex.width, targetH: tex.height, flip: true)
        cb.commit()
        cb.waitUntilCompleted()
    }

    private func encodeAll(commandBuffer cb: MTLCommandBuffer, fd: FrameData,
                           target: MTLTexture, targetW: Int, targetH: Int, flip: Bool) {
        let d = pkg.pkg.defaults
        var u = baseUniforms(fd: fd)
        var cascadeLit: [simd_float4x4] = []
        for c in fd.cascade { cascadeLit.append(c.proj * c.view) }

        // ---- 1. 阴影 pass（3 级） ----
        let shadowOn = d.shadow && quality.shadowSamples > 0
        if shadowOn {
            for i in 0..<3 {
                u.view = fd.cascade[i].view
                u.proj = fd.cascade[i].proj
                u.invView = fd.cascade[i].view.inverse
                writeUniforms(&u)
                let pd = MTLRenderPassDescriptor()
                pd.depthAttachment.texture = shadowTex[i]
                pd.depthAttachment.loadAction = .clear
                pd.depthAttachment.clearDepth = 1.0
                pd.depthAttachment.storeAction = .store
                guard let enc = cb.makeRenderCommandEncoder(descriptor: pd) else { continue }
                enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(quality.shadowMapSize),
                                            height: Double(quality.shadowMapSize), znear: 0, zfar: 1))
                enc.setVertexBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
                encodeGroups(enc: enc, fd: fd, shadow: true)
                encodeDebris(enc: enc, shadow: true)
                encodeCharacters(enc: enc, shadow: true)
                enc.endEncoding()
            }
        }

        // ---- 2. G-buffer ----
        u.view = fd.view; u.proj = fd.proj; u.invView = fd.view.inverse
        u.lightMat = (cascadeLit[0], cascadeLit[1], cascadeLit[2])
        writeUniforms(&u)
        let gb = MTLRenderPassDescriptor()
        gb.colorAttachments[0].texture = albedoTex; gb.colorAttachments[0].loadAction = .clear
        gb.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        gb.colorAttachments[0].storeAction = .store
        gb.colorAttachments[1].texture = normalTex; gb.colorAttachments[1].loadAction = .clear
        gb.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        gb.colorAttachments[1].storeAction = .store
        gb.colorAttachments[2].texture = viewposTex; gb.colorAttachments[2].loadAction = .clear
        gb.colorAttachments[2].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        gb.colorAttachments[2].storeAction = .store
        gb.colorAttachments[3].texture = emitTex; gb.colorAttachments[3].loadAction = .clear
        gb.colorAttachments[3].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        gb.colorAttachments[3].storeAction = .store
        gb.depthAttachment.texture = depthTex
        gb.depthAttachment.loadAction = .clear
        gb.depthAttachment.clearDepth = 1.0
        gb.depthAttachment.storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: gb) else { return }
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(internalW), height: Double(internalH), znear: 0, zfar: 1))
        encodeGroups(enc: enc, fd: fd, shadow: false)
        encodeDebris(enc: enc, shadow: false)
        encodeCharacters(enc: enc, shadow: false)
        enc.endEncoding()

        // ---- 3. SSAO + 模糊 ----
        let aoOn = d.ao && quality.aoSamples > 0
        if aoOn {
            u.aoParams = simd_float4(d.aoRadius, 0.025, d.aoIntensity, 1)
            u.numLights = simd_float4(u.numLights.x, Float(quality.aoSamples), 0, 0)
            writeUniforms(&u)
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = aoTexA
            pd.colorAttachments[0].loadAction = .dontCare
            pd.colorAttachments[0].storeAction = .store
            if let e = cb.makeRenderCommandEncoder(descriptor: pd) {
                e.setRenderPipelineState(assets.pipelines.ssao)
                e.setViewport(viewport(internalW, internalH))
                e.setVertexBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
                e.setFragmentBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
                e.setFragmentBuffer(assets.aoKernel, offset: 0, index: Int(BufferIndexAOKernel.rawValue))
                e.setFragmentTexture(viewposTex, index: 0)
                e.setFragmentTexture(normalTex, index: 1)
                e.setFragmentTexture(assets.noiseTexture, index: 2)
                e.setFragmentSamplerState(assets.screenSampler, index: 0)
                e.setFragmentSamplerState(assets.noiseSampler, index: 1)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                e.endEncoding()
            }
            blur(src: aoTexA, dst: aoTexB, dir: simd_float2(1.0 / Float(internalW), 0), cb: cb)
            blur(src: aoTexB, dst: aoTexA, dir: simd_float2(0, 1.0 / Float(internalH)), cb: cb)
        } else {
            u.aoParams = simd_float4(d.aoRadius, 0.025, d.aoIntensity, 0)
        }

        // ---- 4. 光照 ----
        u.aoParams = simd_float4(d.aoRadius, 0.025, d.aoIntensity, aoOn ? 1 : 0)
        writeUniforms(&u)
        let lp = MTLRenderPassDescriptor()
        lp.colorAttachments[0].texture = hdrTex
        lp.colorAttachments[0].loadAction = .dontCare
        lp.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: lp) {
            e.setRenderPipelineState(assets.pipelines.lighting)
            e.setViewport(viewport(internalW, internalH))
            e.setVertexBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
            e.setFragmentBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
            e.setFragmentBuffer(lightsBuffer, offset: 0, index: Int(BufferIndexLights.rawValue))
            e.setFragmentTexture(albedoTex, index: 0)
            e.setFragmentTexture(normalTex, index: 1)
            e.setFragmentTexture(viewposTex, index: 2)
            e.setFragmentTexture(emitTex, index: 3)
            e.setFragmentTexture(aoTexA, index: 4)
            for i in 0..<3 { e.setFragmentTexture(shadowOn ? shadowTex[i] : nil, index: 5 + i) }
            e.setFragmentSamplerState(assets.screenSampler, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }

        // ---- 5. 粒子（加法混合进 hdr） ----
        if assets.activeTracerCount > 0 {
            let pp = MTLRenderPassDescriptor()
            pp.colorAttachments[0].texture = hdrTex
            pp.colorAttachments[0].loadAction = .load
            pp.colorAttachments[0].storeAction = .store
            if let e = cb.makeRenderCommandEncoder(descriptor: pp) {
                e.setViewport(viewport(internalW, internalH))
                e.setVertexBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
                e.setFragmentBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
                // 拖尾
                e.setRenderPipelineState(assets.pipelines.tracer)
                e.setVertexBuffer(assets.templateCornerStrip, offset: 0, index: 0)
                e.setVertexBuffer(assets.tracerInstances, offset: 0, index: Int(BufferIndexParticleInstance.rawValue))
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: assets.activeTracerCount)
                // 点精灵
                e.setRenderPipelineState(assets.pipelines.point)
                e.setVertexBuffer(assets.templateCornerQuad, offset: 0, index: 0)
                e.setVertexBuffer(assets.pointInstances, offset: 0, index: Int(BufferIndexParticleInstance.rawValue))
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: assets.activePointCount)
                e.endEncoding()
            }
        }

        // ---- 6. 泛光 ----
        if quality.bloom && d.bloom {
            var thr = simd_float4(d.bloomThreshold, 0, 0, 0)
            var sm = simd_float4(0, 0, 0, 0)
            bright(src: hdrTex, dst: bloomA, threshold: &thr, smoothness: &sm, cb: cb, w: internalW / 2, h: internalH / 2)
            blur(src: bloomA, dst: bloomB, dir: simd_float2(1.0 / Float(internalW / 2), 0), cb: cb, w: internalW / 2, h: internalH / 2)
            blur(src: bloomB, dst: bloomA, dir: simd_float2(0, 1.0 / Float(internalH / 2)), cb: cb, w: internalW / 2, h: internalH / 2)
            blur(src: bloomA, dst: bloomB, dir: simd_float2(1.0 / Float(internalW / 2), 0), cb: cb, w: internalW / 2, h: internalH / 2)
            blur(src: bloomB, dst: bloomA, dir: simd_float2(0, 1.0 / Float(internalH / 2)), cb: cb, w: internalW / 2, h: internalH / 2)
        }

        // ---- 7. 辉光 ----
        if quality.glare && d.glare {
            var thr = simd_float4(d.glareThreshold, 0, 0, 0)
            var sm = simd_float4(d.glareSmoothness, 0, 0, 0)
            bright(src: hdrTex, dst: glareA, threshold: &thr, smoothness: &sm, cb: cb, w: internalW, h: internalH)
            let radii: [Float] = [1.083, 2.166, 4.332, 8.664]
            for (k, r) in radii.enumerated() {
                blur(src: glareA, dst: glareB, dir: simd_float2(r / Float(internalW), 0), cb: cb, w: internalW, h: internalH)
                blur(src: glareB, dst: glareA, dir: simd_float2(0, r / Float(internalH)), cb: cb, w: internalW, h: internalH)
                _ = k
            }
        }

        // ---- 8. tonemap -> 目标 ----
        u.flipMode = simd_float4(flip ? 1 : 0, 0, 0, 0)
        writeUniforms(&u)
        let tp = MTLRenderPassDescriptor()
        tp.colorAttachments[0].texture = target
        tp.colorAttachments[0].loadAction = .dontCare
        tp.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: tp) {
            e.setRenderPipelineState(assets.pipelines.tonemap)
            e.setViewport(viewport(targetW, targetH))
            e.setVertexBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
            e.setFragmentBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
            e.setFragmentTexture(hdrTex, index: 0)
            e.setFragmentTexture((quality.bloom && d.bloom) ? bloomA : nil, index: 1)
            e.setFragmentTexture((quality.glare && d.glare) ? glareA : nil, index: 2)
            e.setFragmentSamplerState(assets.linearClampSampler, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
    }

    private func viewport(_ w: Int, _ h: Int) -> MTLViewport {
        MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1)
    }

    // MARK: - 场景绘制

    private func pipelineFor(shadow: Bool, skinned: Bool, cut: Bool) -> MTLRenderPipelineState {
        let P = assets.pipelines
        switch (shadow, skinned, cut) {
        case (true, false, false): return P.shadowPlain
        case (true, false, true): return P.shadowPlainCut
        case (true, true, false): return P.shadowSkinned
        case (true, true, true): return P.shadowSkinnedCut
        case (false, false, false): return P.gbufferPlain
        case (false, false, true): return P.gbufferPlainCut
        case (false, true, false): return P.gbufferSkinned
        case (false, true, true): return P.gbufferSkinnedCut
        }
    }

    private func bindMeshCommon(enc: MTLRenderCommandEncoder, mesh: MeshGPU, model: simd_float4x4) {
        var m = model
        // setVertexBytes/setFragmentBytes 的 length 为必填参数（Xcode 16 编译暴露）
        enc.setVertexBytes(&m, length: MemoryLayout<simd_float4x4>.stride, index: Int(BufferIndexModel.rawValue))
        enc.setVertexBuffer(mesh.pos, offset: 0, index: Int(BufferIndexMeshPosition.rawValue))
        enc.setVertexBuffer(mesh.nrm, offset: 0, index: Int(BufferIndexMeshNormal.rawValue))
        enc.setVertexBuffer(mesh.uv, offset: 0, index: Int(BufferIndexMeshUV.rawValue))
    }

    private func setDrawParams(enc: MTLRenderCommandEncoder, tint: simd_float4, emission: simd_float3, hasTex: Bool) {
        var t = tint, e = emission, h: Int32 = hasTex ? 1 : 0
        enc.setFragmentBytes(&t, length: MemoryLayout<simd_float4>.stride, index: 14)
        enc.setFragmentBytes(&e, length: MemoryLayout<simd_float3>.stride, index: 15)
        enc.setFragmentBytes(&h, length: MemoryLayout<Int32>.stride, index: 16)
    }

    /// 静态组（可见性 + 视锥已过滤）
    private func encodeGroups(enc: MTLRenderCommandEncoder, fd: FrameData, shadow: Bool) {
        let p = pkg.pkg
        for i in fd.visibleGroups {
            let g = p.groups[i]
            let mesh = assets.groupMeshes[i]
            let model = fd.frameMats[i] ?? identity
            let cut = g.alphaCut
            enc.setRenderPipelineState(pipelineFor(shadow: shadow, skinned: false, cut: cut))
            bindMeshCommon(enc: enc, mesh: mesh, model: model)
            if let texName = g.texture, let tex = assets.sceneTextures[texName] {
                enc.setFragmentTexture(tex, index: Int(TextureIndexAlbedo.rawValue))
                enc.setFragmentSamplerState(assets.sceneSampler, index: 0)
                setDrawParams(enc: enc, tint: simd_float4(g.color[0], g.color[1], g.color[2], g.color[3]),
                              emission: simd_float3(g.emission[0], g.emission[1], g.emission[2]), hasTex: true)
            } else {
                setDrawParams(enc: enc, tint: simd_float4(g.color[0], g.color[1], g.color[2], g.color[3]),
                              emission: simd_float3(g.emission[0], g.emission[1], g.emission[2]), hasTex: false)
            }
            enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                      indexType: .uint32, indexBuffer: mesh.idx, indexBufferOffset: 0)
        }
    }

    /// 碎块（instanced，跟随事件 group 的贴图/镂空；一次 draw 覆盖全部事件活块）
    private func encodeDebris(enc: MTLRenderCommandEncoder, shadow: Bool) {
        guard assets.activeDebrisCount > 0, let mesh = assets.debrisMesh else { return }
        let p = pkg.pkg
        let shade = p.defaults.debris.shade
        var m = matrix_identity_float4x4
        enc.setVertexBytes(&m, length: MemoryLayout<simd_float4x4>.stride, index: Int(BufferIndexModel.rawValue))
        // 取第一个合法事件所属 group 的外观（同一墙面撞坏事件外观一致）
        guard let ev = debrisEvents.first(where: { $0.group < p.groups.count }) else { return }
        let g = p.groups[ev.group]
        let cut = g.alphaCut
        enc.setRenderPipelineState(shadow
            ? (cut ? assets.pipelines.debrisShadowCut : assets.pipelines.debrisShadow)
            : (cut ? assets.pipelines.debrisGBufferCut : assets.pipelines.debrisGBuffer))
        enc.setVertexBuffer(mesh.pos, offset: 0, index: Int(BufferIndexMeshPosition.rawValue))
        enc.setVertexBuffer(mesh.nrm, offset: 0, index: Int(BufferIndexMeshNormal.rawValue))
        enc.setVertexBuffer(mesh.uv, offset: 0, index: Int(BufferIndexMeshUV.rawValue))
        enc.setVertexBuffer(assets.debrisModels, offset: 0, index: Int(BufferIndexDebrisModel.rawValue))
        if let texName = g.texture, let tex = assets.sceneTextures[texName] {
            enc.setFragmentTexture(tex, index: Int(TextureIndexAlbedo.rawValue))
            enc.setFragmentSamplerState(assets.sceneSampler, index: 0)
            setDrawParams(enc: enc, tint: simd_float4(shade, shade, shade, 1), emission: simd_float3(0, 0, 0), hasTex: true)
        } else {
            setDrawParams(enc: enc, tint: simd_float4(shade, shade, shade, 1), emission: simd_float3(0, 0, 0), hasTex: false)
        }
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32,
                                  indexBuffer: mesh.idx, indexBufferOffset: 0, instanceCount: assets.activeDebrisCount)
    }

    /// 角色部件（蒙皮）
    private func encodeCharacters(enc: MTLRenderCommandEncoder, shadow: Bool) {
        let p = pkg.pkg
        for (ci, c) in p.characters.enumerated() {
            let skinTex = c.skin.flatMap { assets.skinTextures[$0] }
            let bones = bonesBuffers[ci]
            for (pi, part) in c.parts.enumerated() {
                let mesh = assets.partMeshes[ci][pi]
                enc.setRenderPipelineState(pipelineFor(shadow: shadow, skinned: true, cut: part.alphaCut))
                bindMeshCommon(enc: enc, mesh: mesh, model: identity)
                enc.setVertexBuffer(mesh.bi, offset: 0, index: Int(BufferIndexMeshBoneIndex.rawValue))
                enc.setVertexBuffer(mesh.bw, offset: 0, index: Int(BufferIndexMeshBoneWeight.rawValue))
                enc.setVertexBuffer(bones, offset: 0, index: Int(BufferIndexBones.rawValue))
                if let tex = skinTex {
                    enc.setFragmentTexture(tex, index: Int(TextureIndexAlbedo.rawValue))
                    enc.setFragmentSamplerState(assets.skinSampler, index: 0)
                    setDrawParams(enc: enc, tint: simd_float4(1, 1, 1, 1), emission: simd_float3(0, 0, 0), hasTex: true)
                } else {
                    setDrawParams(enc: enc, tint: simd_float4(1, 1, 1, 1), emission: simd_float3(0, 0, 0), hasTex: false)
                }
                enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                          indexType: .uint32, indexBuffer: mesh.idx, indexBufferOffset: 0)
            }
        }
    }

    // MARK: - 全屏 pass 辅助

    private func fullscreen(cb: MTLCommandBuffer, dst: MTLTexture, pipeline: MTLRenderPipelineState,
                            w: Int, h: Int, configure: (MTLRenderCommandEncoder) -> Void) {
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = dst
        pd.colorAttachments[0].loadAction = .dontCare
        pd.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: pd) else { return }
        e.setRenderPipelineState(pipeline)
        e.setViewport(viewport(w, h))
        e.setVertexBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
        e.setFragmentBuffer(uniformBuffer, offset: 0, index: Int(BufferIndexUniforms.rawValue))
        configure(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }

    private func blur(src: MTLTexture, dst: MTLTexture, dir: simd_float2, cb: MTLCommandBuffer, w: Int? = nil, h: Int? = nil) {
        var d = dir
        fullscreen(cb: cb, dst: dst, pipeline: assets.pipelines.blur, w: w ?? src.width, h: h ?? src.height) { e in
            e.setFragmentTexture(src, index: 0)
            e.setFragmentSamplerState(assets.screenSampler, index: 0)
            e.setFragmentBytes(&d, length: MemoryLayout<simd_float2>.stride, index: 14)
        }
    }

    private func bright(src: MTLTexture, dst: MTLTexture, threshold: UnsafeMutablePointer<simd_float4>,
                        smoothness: UnsafeMutablePointer<simd_float4>, cb: MTLCommandBuffer, w: Int, h: Int) {
        fullscreen(cb: cb, dst: dst, pipeline: assets.pipelines.bright, w: w, h: h) { e in
            e.setFragmentTexture(src, index: 0)
            e.setFragmentSamplerState(assets.screenSampler, index: 0)
            e.setFragmentBytes(UnsafeRawPointer(threshold), length: MemoryLayout<simd_float4>.stride, index: 14)
            e.setFragmentBytes(UnsafeRawPointer(smoothness), length: MemoryLayout<simd_float4>.stride, index: 15)
        }
    }
}
