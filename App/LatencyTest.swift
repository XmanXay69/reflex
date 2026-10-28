import AppKit
import Foundation
import MetalKit
import Observation
import ReflexPTP
import ReflexVideo
import SwiftUI

/// Glass-to-glass latency: flip an on-screen target between black and white, find the first camera frame whose
/// luma crossed the midpoint, and subtract the time the flip reached the display (`presentedTime`).
@Observable
final class LatencyTestController {
    struct Result: Equatable {
        var medianMs: Double
        var minMs: Double
        var p90Ms: Double
        var maxMs: Double
        var trials: Int
        var date: Date
    }

    enum State: Equatable {
        case idle
        case running(String)
        case finished(Result)
        case failed(String)
    }

    var state: State = .idle
    var lastResult: Result?
    let target = FlashTarget()

    @ObservationIgnored private let pipeline: VideoPipeline?
    @ObservationIgnored private var samples: [(luma: Double, arrivedAt: Double)] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    init(pipeline: VideoPipeline?) { self.pipeline = pipeline }

    var isRunning: Bool { if case .running = state { true } else { false } }

    func start(trials: Int = 16) {
        guard !isRunning, let pipeline else { return }
        samples.removeAll()
        let probe = LumaProbe { [weak self] luma, arrivedAt in
            Task { @MainActor in
                self?.samples.append((luma, arrivedAt))
                if (self?.samples.count ?? 0) > 600 { self?.samples.removeFirst(100) }
            }
        }
        pipeline.add(probe)
        task = Task {
            defer { pipeline.remove(probe) }
            await run(trials: trials)
        }
    }

    func cancel() {
        task?.cancel()
        state = .idle
    }

    private func run(trials: Int) async {
        state = .running("Calibrating…")
        _ = await target.show(white: false)
        try? await Task.sleep(for: .seconds(1.2))
        let black = medianLuma(since: hostTime() - 0.6)
        _ = await target.show(white: true)
        try? await Task.sleep(for: .seconds(1.2))
        let white = medianLuma(since: hostTime() - 0.6)
        guard white - black > 0.08 else {
            state = .failed("The camera can't see the target change. Point it at the square so it fills most of the frame.")
            return
        }
        let mid = (black + white) / 2
        var latencies: [Double] = []
        var isWhite = true
        for trial in 1...trials {
            guard !Task.isCancelled else { return }
            state = .running("Trial \(trial) of \(trials)")
            isWhite.toggle()
            let shownAt = await target.show(white: isWhite)
            let deadline = hostTime() + 1.5
            while hostTime() < deadline {
                if let hit = samples.first(where: { $0.arrivedAt > shownAt && (isWhite ? $0.luma > mid : $0.luma < mid) }) {
                    latencies.append((hit.arrivedAt - shownAt) * 1000)
                    break
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 350...700)))
        }
        guard latencies.count >= trials / 2 else {
            state = .failed("Too few flips were detected (\(latencies.count) of \(trials)). Keep the camera steady on the square.")
            return
        }
        let sorted = latencies.sorted()
        let result = Result(medianMs: sorted[sorted.count / 2], minMs: sorted.first!, p90Ms: sorted[Int(Double(sorted.count - 1) * 0.9)],
                            maxMs: sorted.last!, trials: sorted.count, date: Date())
        lastResult = result
        state = .finished(result)
    }

    private func medianLuma(since t: Double) -> Double {
        let values = samples.filter { $0.arrivedAt >= t }.map(\.luma).sorted()
        return values.isEmpty ? 0 : values[values.count / 2]
    }
}

/// A Metal surface that flips black/white and reports when each flip reached the display.
final class FlashTarget: NSObject, MTKViewDelegate {
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private weak var view: MTKView?
    private var onPresented: (@Sendable (Double) -> Void)?

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.delegate = self
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        self.view = view
        return view
    }

    func show(white: Bool) async -> Double {
        guard let view else { return hostTime() }
        let level = white ? 1.0 : 0.0
        view.clearColor = MTLClearColor(red: level, green: level, blue: level, alpha: 1)
        return await withCheckedContinuation { continuation in
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
            presented?(drawable.presentedTime > 0 ? drawable.presentedTime : committed)
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

struct FlashTargetView: NSViewRepresentable {
    let target: FlashTarget
    func makeNSView(context: Context) -> MTKView { target.makeView() }
    func updateNSView(_ nsView: MTKView, context: Context) {}
}

struct LatencyTestView: View {
    @Bindable var model: AppModel
    private var controller: LatencyTestController { model.latency }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Measure latency").font(.title3.weight(.semibold))
                Text("Point the camera at the square so it fills most of the frame, keep it still, then start. The square flashes 16 times.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlashTargetView(target: controller.target)
                .aspectRatio(1, contentMode: .fit)
                .frame(minWidth: 240, maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("Flashing latency target")
            HStack {
                resultText
                Spacer()
                if controller.isRunning {
                    Button("Cancel") { controller.cancel() }
                } else {
                    Button("Start") { controller.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.receivingFrames)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420)
        .preferredColorScheme(model.appearance.colorScheme)
    }

    @ViewBuilder private var resultText: some View {
        switch controller.state {
        case .idle:
            Text(model.receivingFrames ? "Ready" : "Waiting for live view…").foregroundStyle(.secondary)
        case let .running(step):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step) }
        case let .finished(r):
            Text(String(format: "%.0f ms median  ·  %.0f–%.0f ms  ·  p90 %.0f ms", r.medianMs, r.minMs, r.maxMs, r.p90Ms))
                .monospacedDigit()
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
        }
    }
}
