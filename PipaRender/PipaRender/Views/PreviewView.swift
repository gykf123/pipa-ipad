//
//  PreviewView.swift
//  PipaRender — MTKView 3D 预览（轨道相机手势 + 帧 scrubber）
//

import SwiftUI
import MetalKit

struct MetalPreview: UIViewRepresentable {
    let renderer: MetalRenderer
    @Binding var frameIndex: Float

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = renderer.device
        v.delegate = context.coordinator
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        v.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .depth32Float
        // 手势：拖动旋转，双指缩放
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 1
        v.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        v.addGestureRecognizer(pinch)
        context.coordinator.view = v
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        context.coordinator.frameIndex = frameIndex
        // 包相机模式下，切帧才需要重绘；自由相机由手势触发
        if renderer.usePackageCamera || context.coordinator.needsRedraw {
            context.coordinator.needsRedraw = false
            renderer.setOutputSize(w: Int(v.bounds.width), h: Int(v.bounds.height))
            v.draw()
        }
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let renderer: MetalRenderer
        var frameIndex: Float = 0
        var needsRedraw = true
        weak var view: MTKView?

        init(renderer: MetalRenderer) {
            self.renderer = renderer
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            renderer.setOutputSize(w: Int(size.width), h: Int(size.height))
            needsRedraw = true
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable else { return }
            renderer.render(sourceFrame: frameIndex, to: drawable)
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            renderer.previewYaw -= Float(t.x) * 0.01
            renderer.previewPitch = min(max(renderer.previewPitch + Float(t.y) * 0.01, -1.4), 1.4)
            needsRedraw = true
            view?.draw()
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            renderer.previewDist = min(max(renderer.previewDist / Float(g.scale), 2), 120)
            g.scale = 1
            needsRedraw = true
            view?.draw()
        }
    }
}
