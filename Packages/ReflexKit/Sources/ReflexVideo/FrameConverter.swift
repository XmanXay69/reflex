import CoreVideo
import Foundation
import Metal
import MetalFX

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

/// Output size of the video pipeline.
public enum OutputScale: String, CaseIterable, Sendable {
    /// The camera's own pixels (1024 wide on a D780).
    case native
    /// Upscaled to 1080 lines with MetalFX's edge-aware spatial upscaler. Looks sharper than a plain resize;
    /// it can't add detail the camera didn't send.
    case hd1080

    func size(for crop: CropRect, upscalerAvailable: Bool) -> (width: Int, height: Int) {
        guard self == .hd1080, upscalerAvailable, crop.height > 0, crop.height < 1080 else { return (crop.width, crop.height) }
        var width = Int((1080 * Double(crop.width) / Double(crop.height)).rounded())
        width -= width % 2
        return (width, 1080)
    }
}

/// Y'CbCr 4:2:0 → RGB with crop, optional MetalFX upscale, optional contrast-adaptive sharpening, ending in an
/// IOSurface-backed BGRA pixel buffer (shareable with Syphon and, later, a camera extension).
final class FrameConverter {
    private let metal: MetalContext
    private let convertPipeline: MTLRenderPipelineState
    private let sharpenPipeline: MTLRenderPipelineState
    let upscalerAvailable: Bool

    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var rgbTexture: MTLTexture?
    private var upscaledTexture: MTLTexture?
    private var scaler: MTLFXSpatialScaler?
    private var scalerKey = (0, 0, 0, 0)

    init(metal: MetalContext) throws {
        self.metal = metal
        convertPipeline = try metal.pipeline(vertex: "fullscreenVertex", fragment: "ycbcrToRGB", pixelFormat: .bgra8Unorm)
        sharpenPipeline = try metal.pipeline(vertex: "fullscreenVertex", fragment: "sharpenFragment", pixelFormat: .bgra8Unorm)
        upscalerAvailable = MTLFXSpatialScalerDescriptor.supportsDevice(metal.device)
    }

    struct Output {
        var pixelBuffer: CVPixelBuffer
        var texture: CVMetalTexture
        var retained: [AnyObject]
    }

    func encode(_ source: CVPixelBuffer, crop: CropRect, scale: OutputScale, sharpness: Float,
                into commandBuffer: MTLCommandBuffer) -> Output? {
        let outSize = scale.size(for: crop, upscalerAvailable: upscalerAvailable)
        guard let luma = metal.texture(from: source, plane: 0, format: .r8Unorm),
              let chroma = metal.texture(from: source, plane: 1, format: .rg8Unorm),
              let output = makeOutputBuffer(width: outSize.width, height: outSize.height),
              let target = metal.texture(from: output, plane: 0, format: .bgra8Unorm),
              let targetTexture = CVMetalTextureGetTexture(target) else { return nil }
        var retained: [AnyObject] = [luma, chroma, target]

        // Simplest case: convert straight into the shareable buffer.
        let direct = outSize == (crop.width, crop.height) && sharpness <= 0
        guard let rgb = direct ? targetTexture : privateTexture(&rgbTexture, width: crop.width, height: crop.height,
                                                                usage: [.shaderRead, .renderTarget]) else { return nil }
        let w = Float(CVPixelBufferGetWidth(source)), h = Float(CVPixelBufferGetHeight(source))
        var cropUniforms = SIMD4<Float>(Float(crop.x) / w, Float(crop.y) / h, Float(crop.width) / w, Float(crop.height) / h)
        guard render(into: rgb, commandBuffer, { encoder in
            encoder.setRenderPipelineState(convertPipeline)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(luma), index: 0)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(chroma), index: 1)
            encoder.setFragmentBytes(&cropUniforms, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        }) else { return nil }
        if direct { return Output(pixelBuffer: output, texture: target, retained: retained) }

        var sharpenSource = rgb
        if outSize != (crop.width, crop.height) {
            guard let scaler = spatialScaler(input: (crop.width, crop.height), output: outSize),
                  let upscaled = privateTexture(&upscaledTexture, width: outSize.width, height: outSize.height,
                                                usage: scaler.outputTextureUsage.union(.shaderRead)) else { return nil }
            scaler.colorTexture = rgb
            scaler.outputTexture = upscaled
            scaler.inputContentWidth = crop.width
            scaler.inputContentHeight = crop.height
            scaler.encode(commandBuffer: commandBuffer)
            retained.append(scaler)
            sharpenSource = upscaled
        }

        var strength = max(0, min(sharpness, 1))
        guard render(into: targetTexture, commandBuffer, { encoder in
            encoder.setRenderPipelineState(sharpenPipeline)
            encoder.setFragmentTexture(sharpenSource, index: 0)
            encoder.setFragmentBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
        }) else { return nil }
        return Output(pixelBuffer: output, texture: target, retained: retained)
    }

    private func render(into texture: MTLTexture, _ commandBuffer: MTLCommandBuffer,
                        _ setup: (MTLRenderCommandEncoder) -> Void) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        setup(encoder)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func spatialScaler(input: (Int, Int), output: (width: Int, height: Int)) -> MTLFXSpatialScaler? {
        let key = (input.0, input.1, output.width, output.height)
        if let scaler, scalerKey == key { return scaler }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = input.0
        descriptor.inputHeight = input.1
        descriptor.outputWidth = output.width
        descriptor.outputHeight = output.height
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual // camera JPEGs are gamma-encoded sRGB
        scaler = descriptor.makeSpatialScaler(device: metal.device)
        scalerKey = key
        return scaler
    }

    private func privateTexture(_ cache: inout MTLTexture?, width: Int, height: Int, usage: MTLTextureUsage) -> MTLTexture? {
        if let texture = cache, texture.width == width, texture.height == height, texture.usage.isSuperset(of: usage) {
            return texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private
        cache = metal.device.makeTexture(descriptor: descriptor)
        return cache
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
