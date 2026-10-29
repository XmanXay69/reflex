import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import ReflexVideo

@Suite struct CropRectTests {
    @Test func photoLiveViewTo16x9() {
        #expect(CropRect.centered(sourceWidth: 1024, sourceHeight: 680, aspect: 16.0 / 9.0)
            == CropRect(x: 0, y: 52, width: 1024, height: 576))
    }

    @Test func movieLiveViewIsAlready16x9() {
        #expect(CropRect.centered(sourceWidth: 1024, sourceHeight: 576, aspect: 16.0 / 9.0)
            == CropRect(x: 0, y: 0, width: 1024, height: 576))
    }

    @Test func movieLiveViewTo3x2CropsTheSides() {
        #expect(CropRect.centered(sourceWidth: 1024, sourceHeight: 576, aspect: 1.5)
            == CropRect(x: 80, y: 0, width: 864, height: 576))
    }

    @Test func nativeKeepsEverything() {
        #expect(CropRect.centered(sourceWidth: 1024, sourceHeight: 680, aspect: nil)
            == CropRect(x: 0, y: 0, width: 1024, height: 680))
    }

    @Test func fitRectLetterboxes() {
        let fit = ViewfinderRenderer.fitRect(imageSize: CGSize(width: 1600, height: 900),
                                             in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(fit == CGRect(x: 0, y: 218.75, width: 1000, height: 562.5))
    }
}

/// Runs a real JPEG through VideoToolbox and Metal and reads the output back.
@Suite struct VideoPipelineTests {
    final class CaptureSink: FrameSink, @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var frame: ProcessedFrame?
        func publish(_ frame: ProcessedFrame, commandBuffer: MTLCommandBuffer) {
            self.frame = frame
            commandBuffer.addCompletedHandler { _ in self.done.signal() }
        }
    }

    /// Top half red, bottom half blue, 1024 × 680 (photo live-view size), encoded as JPEG.
    static func testJPEG() throws -> Data {
        let width = 1024, height = 680
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func run(scale: OutputScale, sharpness: Float) throws -> ProcessedFrame {
        let pipeline = try VideoPipeline(metal: MetalContext())
        pipeline.setEnhancement(scale: scale, sharpness: sharpness)
        let sink = CaptureSink()
        pipeline.add(sink)
        pipeline.submit(CompressedFrame(jpeg: try Self.testJPEG(), width: 1024, height: 680, sequence: 1,
                                        requestedAt: 0, arrivedAt: 0))
        #expect(sink.done.wait(timeout: .now() + 5) == .success)
        return try #require(sink.frame)
    }

    private func expectRedOverBlue(_ frame: ProcessedFrame) throws {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func bgra(_ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int) {
            let p = base + y * stride + x * 4
            return (Int(p[0]), Int(p[1]), Int(p[2]))
        }
        let top = bgra(frame.width / 2, frame.height / 6), bottom = bgra(frame.width / 2, frame.height * 5 / 6)
        #expect(top.r > 220 && top.g < 40 && top.b < 40, "top should be red, got \(top)")
        #expect(bottom.b > 220 && bottom.r < 40 && bottom.g < 40, "bottom should be blue, got \(bottom)")
    }

    @Test func decodesConvertsAndCrops() throws {
        let frame = try run(scale: .native, sharpness: 0)
        #expect(frame.width == 1024 && frame.height == 576)
        try expectRedOverBlue(frame)
    }

    @Test func sharpensAtNativeSize() throws {
        let frame = try run(scale: .native, sharpness: 0.6)
        #expect(frame.width == 1024 && frame.height == 576)
        try expectRedOverBlue(frame)
    }

    @Test func upscalesTo1080WithMetalFX() throws {
        let pipeline = try VideoPipeline(metal: MetalContext())
        try #require(pipeline.upscalerAvailable, "MetalFX spatial upscaling unsupported on this GPU")
        let frame = try run(scale: .hd1080, sharpness: 0.5)
        #expect(frame.width == 1920 && frame.height == 1080)
        try expectRedOverBlue(frame)
    }
}
