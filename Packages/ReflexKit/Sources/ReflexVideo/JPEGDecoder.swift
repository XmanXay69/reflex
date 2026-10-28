import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decodes baseline JPEG frames with VideoToolbox straight into IOSurface-backed, Metal-compatible
/// full-range 4:2:0 pixel buffers (`420f`). Measured on an M5: ~0.5 ms for a 1024×576 live-view frame.
final class JPEGDecoder {
    enum Failure: Error, CustomStringConvertible {
        case session(OSStatus), decode(OSStatus), noOutput

        var description: String {
            switch self {
            case let .session(s): "VideoToolbox session failed (\(s))"
            case let .decode(s): "VideoToolbox decode failed (\(s))"
            case .noOutput: "VideoToolbox produced no image"
            }
        }
    }

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var size = (width: 0, height: 0)

    deinit { invalidate() }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
    }

    func decode(_ jpeg: Data, width: Int, height: Int) throws -> CVPixelBuffer {
        if session == nil || size != (width, height) { try makeSession(width: width, height: height) }
        guard let session, let format else { throw Failure.noOutput }
        let sample = try Self.sampleBuffer(jpeg, format: format)
        let output = OutputBox()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            output.status = status
            output.buffer = buffer
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr else {
            invalidate() // a broken session won't recover; rebuild on the next frame
            throw Failure.decode(status)
        }
        guard output.status == noErr, let buffer = output.buffer else { throw Failure.decode(output.status) }
        return buffer
    }

    private func makeSession(width: Int, height: Int) throws {
        invalidate()
        var format: CMVideoFormatDescription?
        let made = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_JPEG, width: Int32(width),
                                                  height: Int32(height), extensions: nil, formatDescriptionOut: &format)
        guard made == noErr, let format else { throw Failure.session(made) }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let spec = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec,
                                                  imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                                  decompressionSessionOut: &session)
        guard status == noErr, let session else { throw Failure.session(status) }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        self.session = session
        self.format = format
        self.size = (width, height)
    }

    private static func sampleBuffer(_ jpeg: Data, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: jpeg.count,
                                                        blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: jpeg.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                        blockBufferOut: &block)
        guard status == noErr, let block else { throw Failure.decode(status) }
        status = jpeg.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: jpeg.count)
        }
        guard status == noErr else { throw Failure.decode(status) }
        var sample: CMSampleBuffer?
        var size = jpeg.count
        status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                           sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                           sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw Failure.decode(status) }
        return sample
    }

    private final class OutputBox: @unchecked Sendable {
        var status: OSStatus = noErr
        var buffer: CVImageBuffer?
    }
}
