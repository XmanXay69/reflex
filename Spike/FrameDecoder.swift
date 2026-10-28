import ReflexPTP
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import VideoToolbox

/// A decoded frame plus the luminance probe used by the latency test.
nonisolated struct DecodedFrame: @unchecked Sendable {
    var image: CGImage
    var meanLuma: Double
    /// Mean red / mean blue of the central region (white-balance probe).
    var redBlueRatio: Double
    var arrivedAt: Double
    var decodedAt: Double
    var decodeSeconds: Double
    var sequence: Int
}

/// Decodes live-view JPEGs on a dedicated queue. Latest-wins: if decoding falls behind, stale frames
/// are dropped instead of queued, so latency never accumulates.
nonisolated final class FrameDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "reflex.spike.decode", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: LiveFrame?
    private var draining = false
    private let onDecoded: @Sendable (DecodedFrame) -> Void
    private(set) var dropped = 0

    init(onDecoded: @escaping @Sendable (DecodedFrame) -> Void) { self.onDecoded = onDecoded }

    func submit(_ frame: LiveFrame) {
        lock.lock()
        if pending != nil { dropped += 1 }
        pending = frame
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let frame = pending else { draining = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            let t0 = hostTime()
            guard let image = Self.decodeImageIO(frame.frame.jpeg) else { continue }
            let t1 = hostTime()
            let probe = Self.probe(image)
            onDecoded(DecodedFrame(image: image, meanLuma: probe.luma, redBlueRatio: probe.redBlue, arrivedAt: frame.arrivedAt,
                                   decodedAt: t1, decodeSeconds: t1 - t0, sequence: frame.sequence))
        }
    }

    static func decodeImageIO(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Mean luma (0...1) and red/blue ratio of the central region, from a 16×16 downsample.
    static func probe(_ image: CGImage) -> (luma: Double, redBlue: Double) {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return (0, 1) }
        var sum = 0.0, red = 0.0, blue = 0.0, count = 0.0
        for y in 4..<12 {
            for x in 4..<12 {
                let i = (y * side + x) * 4
                sum += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
                red += Double(pixels[i])
                blue += Double(pixels[i + 2])
                count += 1
            }
        }
        return (sum / count / 255, red / max(blue, 1))
    }
}

// MARK: - Offline decode benchmark (ImageIO vs VideoToolbox)

nonisolated struct DecodeBenchmark: Codable, Sendable {
    struct Row: Codable, Sendable {
        var method: String
        var iterations: Int
        var meanMs: Double
        var p95Ms: Double
        var hardwareAccelerated: Bool?
        var note: String?
    }
    var width: Int
    var height: Int
    var jpegKB: Double
    var rows: [Row]

    static func run(jpeg: Data, iterations: Int = 200) -> DecodeBenchmark {
        let frame = NikonLiveViewFrame(payload: jpeg)
        let dims = frame?.jpegDimensions ?? (0, 0)
        var rows: [Row] = []

        var times: [Double] = []
        for _ in 0..<iterations {
            let t0 = hostTime()
            _ = FrameDecoder.decodeImageIO(jpeg)
            times.append(hostTime() - t0)
        }
        rows.append(Row(method: "ImageIO → CGImage", iterations: iterations, meanMs: mean(times) * 1000,
                        p95Ms: percentile(times.sorted(), 0.95) * 1000, hardwareAccelerated: nil, note: nil))

        for (label, format) in [("VideoToolbox → BGRA", kCVPixelFormatType_32BGRA),
                                ("VideoToolbox → native YCbCr", OSType(0))] {
            rows.append(videoToolbox(jpeg: jpeg, width: dims.0, height: dims.1, pixelFormat: format,
                                     label: label, iterations: iterations))
        }
        return DecodeBenchmark(width: dims.0, height: dims.1, jpegKB: Double(jpeg.count) / 1024, rows: rows)
    }

    private static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

    private static func videoToolbox(jpeg: Data, width: Int, height: Int, pixelFormat: OSType,
                                     label: String, iterations: Int) -> Row {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_JPEG,
                                             width: Int32(width), height: Int32(height), extensions: nil,
                                             formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else {
            return Row(method: label, iterations: 0, meanMs: 0, p95Ms: 0, hardwareAccelerated: nil, note: "format description failed")
        }
        var attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                           kCVPixelBufferMetalCompatibilityKey: true]
        if pixelFormat != 0 { attributes[kCVPixelBufferPixelFormatTypeKey] = pixelFormat }
        var session: VTDecompressionSession?
        let spec = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: formatDescription,
                                                  decoderSpecification: spec,
                                                  imageBufferAttributes: attributes as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &session)
        guard status == noErr, let session else {
            return Row(method: label, iterations: 0, meanMs: 0, p95Ms: 0, hardwareAccelerated: nil, note: "session create failed (\(status))")
        }
        defer { VTDecompressionSessionInvalidate(session) }

        var hardware: CFBoolean?
        _ = withUnsafeMutablePointer(to: &hardware) {
            VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  allocator: nil, valueOut: $0)
        }

        var times: [Double] = []
        var outputFormat = ""
        var failures = 0
        for _ in 0..<iterations {
            guard let sample = makeSample(jpeg: jpeg, format: formatDescription) else { failures += 1; continue }
            let t0 = hostTime()
            let output = OutputBox()
            let decodeStatus = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                                 infoFlagsOut: nil) { status, _, buffer, _, _ in
                if status == noErr { output.buffer = buffer }
            }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            if decodeStatus == noErr, let produced = output.buffer {
                times.append(hostTime() - t0)
                if outputFormat.isEmpty { outputFormat = fourCC(CVPixelBufferGetPixelFormatType(produced)) }
            } else {
                failures += 1
            }
        }
        let note = "output \(outputFormat.isEmpty ? "none" : outputFormat)" + (failures > 0 ? ", \(failures) failures" : "")
        return Row(method: label, iterations: times.count, meanMs: mean(times) * 1000,
                   p95Ms: percentile(times.sorted(), 0.95) * 1000,
                   hardwareAccelerated: hardware.map { CFBooleanGetValue($0) }, note: note)
    }

    private static func makeSample(jpeg: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: jpeg.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: jpeg.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = jpeg.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: jpeg.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = jpeg.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    private final class OutputBox: @unchecked Sendable { var buffer: CVImageBuffer? }

    private static func fourCC(_ code: OSType) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
        return String(chars)
    }
}
