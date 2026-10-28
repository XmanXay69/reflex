import CoreVideo
import Foundation
import Metal

/// A crop rectangle in source pixels.
public struct CropRect: Equatable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int

    /// The largest centered rectangle of `aspect` (width / height) inside the source, with even sizes.
    /// `aspect == nil` keeps the whole source.
    public static func centered(sourceWidth: Int, sourceHeight: Int, aspect: Double?) -> CropRect {
        guard let aspect, sourceWidth > 0, sourceHeight > 0 else {
            return CropRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        }
        var width = sourceWidth
        var height = Int((Double(sourceWidth) / aspect).rounded())
        if height > sourceHeight {
            height = sourceHeight
            width = Int((Double(sourceHeight) * aspect).rounded())
        }
        width -= width % 2
        height -= height % 2
        return CropRect(x: (sourceWidth - width) / 2, y: (sourceHeight - height) / 2, width: width, height: height)
    }
}

/// One Metal pass: full-range Y'CbCr 4:2:0 → RGB, cropped, into an IOSurface-backed BGRA pixel buffer
/// (shareable with Syphon and, later, a camera extension).
final class FrameConverter {
    private let metal: MetalContext
    private let pipeline: MTLRenderPipelineState
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)

    init(metal: MetalContext) throws {
        self.metal = metal
        pipeline = try metal.pipeline(vertex: "fullscreenVertex", fragment: "ycbcrToRGB", pixelFormat: .bgra8Unorm)
    }

    struct Output {
        var pixelBuffer: CVPixelBuffer
        var texture: CVMetalTexture
        var retained: [CVMetalTexture]
    }

    func encode(_ source: CVPixelBuffer, crop: CropRect, into commandBuffer: MTLCommandBuffer) -> Output? {
        guard let luma = metal.texture(from: source, plane: 0, format: .r8Unorm),
              let chroma = metal.texture(from: source, plane: 1, format: .rg8Unorm),
              let output = makeOutputBuffer(width: crop.width, height: crop.height),
              let target = metal.texture(from: output, plane: 0, format: .bgra8Unorm),
              let targetTexture = CVMetalTextureGetTexture(target) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targetTexture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let w = Float(CVPixelBufferGetWidth(source)), h = Float(CVPixelBufferGetHeight(source))
        var uniforms = SIMD4<Float>(Float(crop.x) / w, Float(crop.y) / h, Float(crop.width) / w, Float(crop.height) / h)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(luma), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(chroma), index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return Output(pixelBuffer: output, texture: target, retained: [luma, chroma, target])
    }

    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, poolAttributes, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
