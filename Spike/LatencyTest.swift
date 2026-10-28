import ReflexPTP
import Foundation
import MetalKit
import SwiftUI

/// A full-window Metal surface that flips between black and white and reports the host time at which
/// each flip actually reached the display (CAMetalDrawable.presentedTime).
final class LatencyTarget: NSObject, MTKViewDelegate {
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private weak var view: MTKView?
    private var onPresented: (@Sendable (Double) -> Void)?
    private(set) var isWhite = false

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.delegate = self
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.view = view
        return view
    }

    var isOnScreen: Bool { view?.window?.isVisible == true }

    /// Flips the target and returns the presentation host time (falls back to commit time).
    func show(white: Bool) async -> Double {
        isWhite = white
        guard let view else { return hostTime() }
        let level = white ? 1.0 : 0.0
        view.clearColor = MTLClearColor(red: level, green: level, blue: level, alpha: 1)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Double, Never>) in
            let once = Once(continuation)
            onPresented = { once.resume($0) }
            let fallback = hostTime() + 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { once.resume(fallback) }
            view.draw()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let presented = onPresented
        onPresented = nil
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue?.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            presented?(hostTime())
            return
        }
        encoder.endEncoding()
        let committed = hostTime()
        drawable.addPresentedHandler { drawable in
            let t = drawable.presentedTime
            presented?(t > 0 ? t : committed)
        }
        buffer.present(drawable)
        buffer.commit()
    }

    nonisolated private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Double, Never>?
        init(_ c: CheckedContinuation<Double, Never>) { continuation = c }
        func resume(_ value: Double) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }
}

struct LatencyTargetView: NSViewRepresentable {
    let target: LatencyTarget
    func makeNSView(context: Context) -> MTKView { target.makeView() }
    func updateNSView(_ nsView: MTKView, context: Context) {}
}

/// Glass-to-glass latency: flip the on-screen target, then find the first camera frame whose luma
/// crossed the midpoint. Latency = frame arrival (host) − flip presentation (host).
final class LatencyTest {
    struct Trial: Codable {
        var toWhite: Bool
        var latencyMs: Double
        var decodedLatencyMs: Double
    }

    struct Result: Codable {
        var blackLuma: Double
        var whiteLuma: Double
        var trials: [Trial]
        var timeouts: Int
        var medianMs: Double
        var minMs: Double
        var maxMs: Double
        var p90Ms: Double
        var medianDecodedMs: Double
        var note: String
    }

    private struct Sample { var luma: Double; var arrivedAt: Double; var decodedAt: Double }
    private var samples: [Sample] = []

    func feed(_ frame: DecodedFrame) {
        samples.append(Sample(luma: frame.meanLuma, arrivedAt: frame.arrivedAt, decodedAt: frame.decodedAt))
        if samples.count > 600 { samples.removeFirst(samples.count - 600) }
    }

    func run(target: LatencyTarget, trials: Int, log: (String) -> Void) async -> Result? {
        _ = await target.show(white: false)
        try? await Task.sleep(for: .seconds(1.5))
        let black = medianLuma(since: hostTime() - 0.7)
        _ = await target.show(white: true)
        try? await Task.sleep(for: .seconds(1.5))
        let white = medianLuma(since: hostTime() - 0.7)
        log(String(format: "Latency calibration: black %.3f, white %.3f", black, white))
        guard white - black > 0.08 else {
            log("Latency test aborted: the camera does not see the target change (point it at the Latency Target window).")
            return nil
        }
        let mid = (black + white) / 2

        var results: [Trial] = []
        var timeouts = 0
        var isWhite = true
        for _ in 0..<trials {
            isWhite.toggle()
            let presentedAt = await target.show(white: isWhite)
            let deadline = hostTime() + 1.5
            var hit: Sample?
            while hit == nil, hostTime() < deadline {
                hit = samples.first { $0.arrivedAt > presentedAt && (isWhite ? $0.luma > mid : $0.luma < mid) }
                if hit == nil { try? await Task.sleep(for: .milliseconds(2)) }
            }
            if let hit {
                results.append(Trial(toWhite: isWhite, latencyMs: (hit.arrivedAt - presentedAt) * 1000,
                                     decodedLatencyMs: (hit.decodedAt - presentedAt) * 1000))
            } else {
                timeouts += 1
            }
            // Random hold so flips don't phase-lock with the camera's frame clock.
            try? await Task.sleep(for: .milliseconds(Int.random(in: 350...750)))
        }
        let latencies = results.map(\.latencyMs).sorted()
        return Result(blackLuma: black, whiteLuma: white, trials: results, timeouts: timeouts,
                      medianMs: percentile(latencies, 0.5), minMs: latencies.first ?? 0, maxMs: latencies.last ?? 0,
                      p90Ms: percentile(latencies, 0.9), medianDecodedMs: median(results.map(\.decodedLatencyMs)),
                      note: "Display → camera sensor → USB → host. Excludes preview-window display time (≈1 refresh).")
    }

    private func medianLuma(since t: Double) -> Double {
        median(samples.filter { $0.decodedAt >= t }.map(\.luma))
    }
}
