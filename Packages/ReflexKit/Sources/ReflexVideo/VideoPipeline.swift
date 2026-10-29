import CoreVideo
import Foundation
import Metal
import ReflexPTP

/// A compressed frame from any JPEG-producing source (USB live view today).
public struct CompressedFrame: Sendable {
    public var jpeg: Data
    public var width: Int
    public var height: Int
    public var sequence: Int
    /// Host times (`hostTime()` clock): request sent to the source, data arrived.
    public var requestedAt: Double
    public var arrivedAt: Double

    public init(jpeg: Data, width: Int, height: Int, sequence: Int, requestedAt: Double, arrivedAt: Double) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.sequence = sequence
        self.requestedAt = requestedAt
        self.arrivedAt = arrivedAt
    }
}

/// A decoded, cropped RGB frame on the GPU, ready for the viewfinder and output sinks.
public struct ProcessedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let texture: MTLTexture
    let cvTexture: CVMetalTexture
    public let sequence: Int
    public let requestedAt: Double
    public let arrivedAt: Double
    public let decodedAt: Double

    public var width: Int { texture.width }
    public var height: Int { texture.height }
}

/// Receives every processed frame, encoded into the pipeline's command buffer (viewfinder, Syphon, …).
public protocol FrameSink: AnyObject, Sendable {
    func publish(_ frame: ProcessedFrame, commandBuffer: MTLCommandBuffer)
}

/// Decode → convert/crop → fan out to sinks, on one serial queue with latest-wins hand-off:
/// if a new frame arrives while one is being processed, the waiting frame is replaced, never queued.
public final class VideoPipeline: @unchecked Sendable {
    public let metal: MetalContext
    private let queue = DispatchQueue(label: "reflex.video", qos: .userInteractive)
    private let decoder = JPEGDecoder()
    private let converter: FrameConverter

    private let lock = NSLock()
    private var pending: CompressedFrame?
    private var draining = false
    private var aspect: Double? = 16.0 / 9.0
    private var scale: OutputScale = .native
    private var sharpness: Float = 0
    private var sinks: [ObjectIdentifier: FrameSink] = [:]
    private var counters = PipelineCounters()
    private var latest: ProcessedFrame?

    public init(metal: MetalContext) throws {
        self.metal = metal
        converter = try FrameConverter(metal: metal)
    }

    /// Output aspect ratio (width / height); nil keeps the camera's own framing.
    public func setAspect(_ aspect: Double?) { lock.withLock { self.aspect = aspect } }

    /// Output size (native or MetalFX-upscaled 1080p) and sharpening strength (0…1).
    public func setEnhancement(scale: OutputScale, sharpness: Float) {
        lock.withLock {
            self.scale = scale
            self.sharpness = sharpness
        }
    }

    /// Whether this GPU supports the MetalFX upscaler used for `.hd1080`.
    public var upscalerAvailable: Bool { converter.upscalerAvailable }

    public func add(_ sink: FrameSink) { lock.withLock { sinks[ObjectIdentifier(sink)] = sink } }
    public func remove(_ sink: FrameSink) { lock.withLock { _ = sinks.removeValue(forKey: ObjectIdentifier(sink)) } }

    public var latestFrame: ProcessedFrame? { lock.withLock { latest } }

    public func submit(_ frame: CompressedFrame) {
        let start = lock.withLock { () -> Bool in
            if pending != nil { counters.dropped += 1 }
            pending = frame
            defer { draining = true }
            return !draining
        }
        if start { queue.async { self.drain() } }
    }

    public func takeCounters() -> PipelineCounters {
        lock.withLock {
            let c = counters
            counters = PipelineCounters()
            return c
        }
    }

    /// Called by the viewfinder when a frame actually reached the screen.
    public func recordPresentation(of frame: ProcessedFrame, at presentedAt: Double) {
        lock.withLock {
            counters.presented += 1
            counters.usbToScreen.append(presentedAt - frame.arrivedAt)
        }
    }

    private func drain() {
        while true {
            let next = lock.withLock { () -> (CompressedFrame, Settings, [FrameSink])? in
                guard let frame = pending else { draining = false; return nil }
                pending = nil
                return (frame, Settings(aspect: aspect, scale: scale, sharpness: sharpness), Array(sinks.values))
            }
            guard let (frame, settings, sinks) = next else { return }
            autoreleasepool { process(frame, settings: settings, sinks: sinks) }
        }
    }

    private struct Settings {
        var aspect: Double?
        var scale: OutputScale
        var sharpness: Float
    }

    private func process(_ frame: CompressedFrame, settings: Settings, sinks: [FrameSink]) {
        let started = hostTime()
        let decoded: CVPixelBuffer
        do {
            decoded = try decoder.decode(frame.jpeg, width: frame.width, height: frame.height)
        } catch {
            lock.withLock { counters.decodeErrors += 1 }
            return
        }
        let decodedAt = hostTime()
        let crop = CropRect.centered(sourceWidth: CVPixelBufferGetWidth(decoded),
                                     sourceHeight: CVPixelBufferGetHeight(decoded), aspect: settings.aspect)
        guard let commandBuffer = metal.queue.makeCommandBuffer(),
              let output = converter.encode(decoded, crop: crop, scale: settings.scale, sharpness: settings.sharpness,
                                            into: commandBuffer),
              let texture = CVMetalTextureGetTexture(output.texture) else { return }
        let processed = ProcessedFrame(pixelBuffer: output.pixelBuffer, texture: texture, cvTexture: output.texture,
                                       sequence: frame.sequence, requestedAt: frame.requestedAt,
                                       arrivedAt: frame.arrivedAt, decodedAt: decodedAt)
        for sink in sinks { sink.publish(processed, commandBuffer: commandBuffer) }
        // Keep the decoded frame and texture wrappers alive until the GPU is done with them.
        let keepAlive = KeepAlive(output.retained + [decoded])
        commandBuffer.addCompletedHandler { [weak self] buffer in
            keepAlive.release()
            let gpu = buffer.gpuEndTime - buffer.gpuStartTime
            if gpu > 0 { self?.lock.withLock { self?.counters.gpuTotal += gpu; self?.counters.gpuFrames += 1 } }
        }
        commandBuffer.commit()
        lock.withLock {
            latest = processed
            counters.processed += 1
            counters.decodeTotal += decodedAt - started
            counters.lastSize = (processed.width, processed.height)
        }
    }
}

private final class KeepAlive: @unchecked Sendable {
    private var objects: [AnyObject]?
    init(_ objects: [AnyObject]) { self.objects = objects }
    func release() { objects = nil }
}

/// Pipeline counters since the last `takeCounters()`.
public struct PipelineCounters: Sendable {
    public var processed = 0
    public var presented = 0
    public var dropped = 0
    public var decodeErrors = 0
    public var decodeTotal = 0.0
    public var gpuTotal = 0.0
    public var gpuFrames = 0
    public var usbToScreen: [Double] = []
    public var lastSize = (width: 0, height: 0)
    public var since = hostTime()

    public var seconds: Double { max(hostTime() - since, 0.001) }
    public var presentedFPS: Double { Double(presented) / seconds }
    public var meanDecode: Double { processed == 0 ? 0 : decodeTotal / Double(processed) }
    /// GPU time per frame (convert, upscale, sharpen, viewfinder draw).
    public var meanGPU: Double { gpuFrames == 0 ? 0 : gpuTotal / Double(gpuFrames) }
    public var medianUSBToScreen: Double? {
        guard !usbToScreen.isEmpty else { return nil }
        return usbToScreen.sorted()[usbToScreen.count / 2]
    }
}
