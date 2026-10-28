import CoreGraphics
import Foundation
import Metal
import QuartzCore

/// Draws processed frames aspect-fit into a `CAMetalLayer`, in the pipeline's own command buffer, so a frame
/// reaches the screen on the next display refresh after it's converted. No display link, no extra copy.
public final class ViewfinderRenderer: FrameSink, @unchecked Sendable {
    public let layer = CAMetalLayer()
    private let metal: MetalContext
    private let pipeline: MTLRenderPipelineState
    private let lock = NSLock()
    private var lastFrame: ProcessedFrame?
    private let onPresented: @Sendable (ProcessedFrame, Double) -> Void

    public init(metal: MetalContext, onPresented: @escaping @Sendable (ProcessedFrame, Double) -> Void) throws {
        self.metal = metal
        self.onPresented = onPresented
        pipeline = try metal.pipeline(vertex: "fitVertex", fragment: "textureFragment", pixelFormat: .bgra8Unorm)
        layer.device = metal.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.isOpaque = true
    }

    public func publish(_ frame: ProcessedFrame, commandBuffer: MTLCommandBuffer) {
        lock.withLock { lastFrame = frame }
        encode(frame, into: commandBuffer, reportPresentation: true)
    }

    /// Redraws the last frame (after a resize). Safe from any thread.
    public func redraw() {
        guard let frame = lock.withLock({ lastFrame }), let commandBuffer = metal.queue.makeCommandBuffer() else { return }
        encode(frame, into: commandBuffer, reportPresentation: false)
        commandBuffer.commit()
    }

    /// Size of the most recent frame, for mapping clicks to image coordinates.
    public var frameSize: CGSize? { lock.withLock { lastFrame.map { CGSize(width: $0.width, height: $0.height) } } }

    /// Where an image of `imageSize` lands inside `bounds` when aspect-fit.
    public static func fitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func encode(_ frame: ProcessedFrame, into commandBuffer: MTLCommandBuffer, reportPresentation: Bool) {
        let drawableSize = layer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0, let drawable = layer.nextDrawable() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let fit = Self.fitRect(imageSize: CGSize(width: frame.width, height: frame.height),
                               in: CGRect(origin: .zero, size: drawableSize))
        var scale = SIMD2<Float>(Float(fit.width / drawableSize.width), Float(fit.height / drawableSize.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentTexture(frame.texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        if reportPresentation {
            let report = onPresented
            drawable.addPresentedHandler { drawable in
                if drawable.presentedTime > 0 { report(frame, drawable.presentedTime) }
            }
        }
        commandBuffer.present(drawable)
    }
}
