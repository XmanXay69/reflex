import CoreVideo
import Foundation
import Metal

/// Samples the mean luma of the central region of each output frame once the GPU has finished it.
/// Used by the glass-to-glass latency test; attach it only while a test runs.
public final class LumaProbe: FrameSink, @unchecked Sendable {
    private let onSample: @Sendable (_ luma: Double, _ arrivedAt: Double) -> Void

    public init(onSample: @escaping @Sendable (_ luma: Double, _ arrivedAt: Double) -> Void) {
        self.onSample = onSample
    }

    public func publish(_ frame: ProcessedFrame, commandBuffer: MTLCommandBuffer) {
        let report = onSample
        commandBuffer.addCompletedHandler { _ in
            report(Self.centerLuma(frame.pixelBuffer), frame.arrivedAt)
        }
    }

    /// Mean luma (0…1) over a 16×16 grid covering the central half of a BGRA buffer.
    static func centerLuma(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var sum = 0.0
        for gy in 0..<16 {
            for gx in 0..<16 {
                let x = width / 4 + gx * width / 32
                let y = height / 4 + gy * height / 32
                let p = base + y * stride + x * 4
                sum += 0.0722 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.2126 * Double(p[2])
            }
        }
        return sum / 256 / 255
    }
}
