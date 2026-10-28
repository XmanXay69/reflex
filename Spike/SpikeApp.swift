import AppKit
import SwiftUI

@main
struct SpikeApp: App {
    @State private var model = SpikeModel()

    var body: some Scene {
        WindowGroup("Reflex Spike", id: "main") {
            SpikeView(model: model)
                .frame(minWidth: 1100, minHeight: 700)
                .task { model.launch() }
        }
        Window("Latency Target", id: "latency") {
            LatencyTargetView(target: model.latencyTarget)
                .frame(minWidth: 320, minHeight: 320)
        }
        .defaultSize(width: 520, height: 520)
    }
}

struct SpikeView: View {
    @Bindable var model: SpikeModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                PreviewView(layer: model.preview.layer)
                    .aspectRatio(3 / 2, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                stats
            }
            .padding(16)
            .frame(minWidth: 640)

            VStack(alignment: .leading, spacing: 12) {
                Text(model.status).font(.headline)
                if let activity = model.activity {
                    Label(activity, systemImage: "hourglass").foregroundStyle(.secondary)
                }
                controls
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                                Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(index)
                            }
                        }
                    }
                    .onChange(of: model.logLines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            .padding(16)
            .frame(minWidth: 380)
        }
        .onChange(of: model.latencyWindowRequested) { _, requested in
            if requested { openWindow(id: "latency") }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Probe") { Task { await model.probe() } }
                Button(model.liveViewRunning ? "Stop live view" : "Start live view") {
                    if model.liveViewRunning { Task { await model.stopLiveView() } } else { model.startLiveView() }
                }
            }
            HStack {
                Button("Size benchmark") { Task { await model.benchmark() } }
                Button("Decode benchmark") { model.decodeBenchmark() }
                Button("Soak") { Task { await model.soak() } }
            }
            HStack {
                Button("Change a setting") { Task { await model.settingTest() } }
                Button("Latency test") { Task { await model.latency() } }
                Button("Target window") { openWindow(id: "latency") }
            }
            Button("Reveal output") { NSWorkspace.shared.activateFileViewerSelecting([model.outDir]) }
        }
        .disabled(!model.hasCamera && model.activity == nil)
    }

    private var stats: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            if let s = model.snapshot {
                GridRow {
                    metric("Frames", String(format: "%.1f fps", s.uniqueFPS))
                    metric("Requests", String(format: "%.1f /s", s.requestRate))
                    metric("RTT", String(format: "%.1f / %.1f ms", s.rttP50Ms, s.rttP95Ms))
                    metric("Size", "\(s.width)×\(s.height)")
                }
                GridRow {
                    metric("Payload", String(format: "%.0f KB", s.payloadMeanKB))
                    metric("Throughput", String(format: "%.1f MB/s", s.throughputMBps))
                    metric("Decode", String(format: "%.2f ms", s.decodeMeanMs))
                    metric("Luma", String(format: "%.3f", model.lastLuma))
                }
            } else {
                Text("No live view yet").foregroundStyle(.secondary)
            }
        }
        .font(.system(.body, design: .monospaced))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

struct PreviewView: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
