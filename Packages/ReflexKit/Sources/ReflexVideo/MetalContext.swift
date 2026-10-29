import CoreVideo
import Foundation
import Metal

/// Shared Metal objects for the video pipeline and viewfinder.
public final class MetalContext: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let library: MTLLibrary
    public let textureCache: CVMetalTextureCache

    public enum Failure: Error { case noMetalDevice, setupFailed(String) }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw Failure.setupFailed("command queue") }
        // Shaders are compiled from source at launch (a few ms) so the package builds the same with SwiftPM and Xcode.
        let library = try device.makeLibrary(source: Shaders.source, options: nil)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw Failure.setupFailed("texture cache")
        }
        self.device = device
        self.queue = queue
        self.library = library
        self.textureCache = cache
        queue.label = "Reflex video"
    }

    /// Wraps one plane of an IOSurface-backed pixel buffer as a Metal texture without copying.
    func texture(from buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        let planar = CVPixelBufferIsPlanar(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format, width, height, plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    func pipeline(vertex: String, fragment: String, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut { float4 position [[position]]; float2 uv; };

    // Full-screen triangle; uv covers [0,1] over the viewport.
    vertex VertexOut fullscreenVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    struct CropUniforms { float2 origin; float2 size; };

    // JPEG (JFIF) is full-range BT.601 Y'CbCr.
    fragment float4 ycbcrToRGB(VertexOut in [[stage_in]],
                               texture2d<float> luma [[texture(0)]],
                               texture2d<float> chroma [[texture(1)]],
                               constant CropUniforms &crop [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = crop.origin + in.uv * crop.size;
        float y = luma.sample(s, uv).r;
        float2 c = chroma.sample(s, uv).rg - 0.5;
        float3 rgb = float3(y + 1.402 * c.y,
                            y - 0.344136 * c.x - 0.714136 * c.y,
                            y + 1.772 * c.x);
        return float4(saturate(rgb), 1.0);
    }

    struct FitUniforms { float2 scale; };

    // Aspect-fit quad for the viewfinder.
    vertex VertexOut fitVertex(uint vid [[vertex_id]], constant FitUniforms &fit [[buffer(0)]]) {
        float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 p = corners[vid];
        VertexOut out;
        out.position = float4(p * fit.scale, 0.0, 1.0);
        out.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
        return out;
    }

    // Contrast-adaptive sharpening (after AMD's CAS idea): sharpen more where local contrast is low, less where
    // it's already high, so edges don't ring. strength 0 = plain copy.
    fragment float4 sharpenFragment(VertexOut in [[stage_in]],
                                    texture2d<float> image [[texture(0)]],
                                    constant float &strength [[buffer(0)]]) {
        uint2 size = uint2(image.get_width(), image.get_height());
        uint2 p = uint2(in.position.xy);
        float3 c = image.read(p).rgb;
        if (strength <= 0.0) { return float4(c, 1.0); }
        float3 n = image.read(uint2(p.x, max(p.y, 1u) - 1)).rgb;
        float3 s = image.read(uint2(p.x, min(p.y + 1, size.y - 1))).rgb;
        float3 w = image.read(uint2(max(p.x, 1u) - 1, p.y)).rgb;
        float3 e = image.read(uint2(min(p.x + 1, size.x - 1), p.y)).rgb;
        float3 mn = min(c, min(min(n, s), min(w, e)));
        float3 mx = max(c, max(max(n, s), max(w, e)));
        float3 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4)));
        float3 weight = -amp * mix(0.125, 0.2, saturate(strength));
        float3 rgb = (c + weight * (n + s + w + e)) / (1.0 + 4.0 * weight);
        return float4(saturate(rgb), 1.0);
    }

    fragment float4 textureFragment(VertexOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return image.sample(s, in.uv);
    }
    """
}
