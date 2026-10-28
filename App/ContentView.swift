import ReflexCamera
import ReflexVideo
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let viewfinder = model.viewfinder {
                        ViewfinderView(renderer: viewfinder)
                            .accessibilityLabel("Live view")
                    }
                    ViewfinderOverlay(model: model)
                }
                Divider()
                StatusBar(model: model)
            }
            if model.showPanel {
                Divider()
                SidePanel(model: model)
                    .frame(width: Theme.panelWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { model.showPanel.toggle() }
                } label: {
                    Label(model.showPanel ? "Hide Controls" : "Show Controls", systemImage: "sidebar.trailing")
                }
                .help("Show or hide controls (⌥⌘S)")
            }
        }
        .preferredColorScheme(model.appearance.colorScheme)
    }
}

/// Hosts the viewfinder's CAMetalLayer; keeps its drawable size in sync with the view.
struct ViewfinderView: NSViewRepresentable {
    let renderer: ViewfinderRenderer

    func makeNSView(context: Context) -> HostView { HostView(renderer: renderer) }
    func updateNSView(_ nsView: HostView, context: Context) {}

    final class HostView: NSView {
        private let renderer: ViewfinderRenderer

        init(renderer: ViewfinderRenderer) {
            self.renderer = renderer
            super.init(frame: .zero)
            layer = renderer.layer
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            syncDrawableSize()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            syncDrawableSize()
        }

        private func syncDrawableSize() {
            let scale = window?.backingScaleFactor ?? 2
            renderer.layer.contentsScale = scale
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            guard size.width > 0, size.height > 0, size != renderer.layer.drawableSize else { return }
            renderer.layer.drawableSize = size
            renderer.redraw()
        }
    }
}

/// Connection and live-view states drawn over the viewfinder.
struct ViewfinderOverlay: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let error = model.setupError {
                message(icon: "exclamationmark.triangle", title: "Can't start the video pipeline", detail: error, warning: true)
            } else {
                switch model.phase {
                case .searching:
                    message(icon: "camera", title: model.receivingFrames ? "Camera disconnected" : "Connect your D780",
                            detail: "Turn the mode dial to P, S, A or M, connect the camera to this Mac with USB-C, and switch it on.",
                            footnote: "First time? macOS asks to allow the accessory, then to let Reflex access removable volumes. Allow both.")
                case let .connecting(name):
                    progress(title: "Connecting to \(name)…",
                             detail: "macOS reads the memory card first, which can take up to 10 seconds.")
                case let .failed(message):
                    self.message(icon: "exclamationmark.triangle", title: "Couldn't connect", detail: message, warning: true)
                case .connected:
                    connectedState
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.phase)
        .animation(.easeOut(duration: 0.2), value: model.receivingFrames)
    }

    @ViewBuilder private var connectedState: some View {
        if let problem = model.status.problem {
            message(icon: "exclamationmark.triangle", title: "Live view unavailable", detail: problem, warning: true)
        } else if !model.liveViewEnabled {
            VStack(spacing: 14) {
                message(icon: "video.slash", title: "Live view is off", detail: nil)
                Button("Start Live View") { model.toggleLiveView() }
                    .controlSize(.large)
            }
            .padding(28)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        } else if !model.receivingFrames {
            progress(title: "Starting live view…", detail: nil)
        }
    }

    private func message(icon: String, title: String, detail: String?, footnote: String? = nil, warning: Bool = false) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(warning ? Theme.warning : .white.opacity(0.7))
            Text(title).font(.title3.weight(.medium)).foregroundStyle(.white)
            if let detail {
                Text(detail).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
            }
            if let footnote {
                Text(footnote).font(.callout).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center).padding(.top, 6)
            }
        }
        .frame(maxWidth: 420)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.receivingFrames ? Color.black.opacity(0.6) : Color.clear)
        .accessibilityElement(children: .combine)
    }

    private func progress(title: String, detail: String?) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular).tint(.white)
            Text(title).foregroundStyle(.white.opacity(0.85))
            if let detail { Text(detail).font(.callout).foregroundStyle(.white.opacity(0.5)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct StatusBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(connectionText).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            if model.receivingFrames {
                metric("\(model.stats.width)×\(model.stats.height)", help: "Output frame size")
                metric(String(format: "%.0f fps", model.stats.fps.rounded()), help: "Frames shown per second")
                if let ms = model.stats.usbToScreenMs {
                    metric(String(format: "%.0f ms", ms), help: "USB → screen: time from a frame arriving over USB to it appearing here. The camera adds its own delay before that; use Camera → Measure Latency for the full glass-to-glass figure.")
                }
            }
            if let battery = model.status.batteryPercent {
                Label("\(battery)%", systemImage: batterySymbol(battery))
                    .foregroundStyle(battery <= 15 ? Theme.warning : .secondary)
                    .help("Camera battery")
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: Theme.statusBarHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func metric(_ text: String, help: String) -> some View {
        Text(text).help(help).accessibilityLabel(help.components(separatedBy: ":").first ?? help).accessibilityValue(text)
    }

    private var dotColor: Color {
        switch model.phase {
        case .connected where model.status.problem != nil: Theme.warning
        case .connected: model.receivingFrames ? Color.primary.opacity(0.85) : Color.secondary
        case .failed: Theme.warning
        case .searching, .connecting: Color.secondary.opacity(0.5)
        }
    }

    private var connectionText: String {
        switch model.phase {
        case .searching: "No camera"
        case let .connecting(name): "Connecting to \(name)…"
        case .failed: "Connection failed"
        case .connected:
            [model.identity?.model, model.status.liveViewMode.map { "\($0.label) live view" },
             model.identity?.usbLinkSpeed?.label].compactMap { $0 }.joined(separator: "  ·  ")
        }
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
