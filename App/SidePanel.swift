import ReflexCamera
import SwiftUI

struct SidePanel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                cameraSection
                outputSection
                diagnosticsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Camera

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Camera")
            if let identity = model.identity {
                row("Model", identity.model)
                row("Firmware", identity.firmware)
                if let mode = model.status.liveViewMode {
                    row("Live view", mode.label, help: "Set with the live view switch on the camera. Photo live view has the lowest latency.")
                    if mode == .movie {
                        note("Movie live view adds 60–175 ms of delay. Flip the camera's switch to photo for the lowest latency.")
                    }
                }
                if let speed = identity.usbLinkSpeed {
                    row("Connection", speed.label, warning: speed.isUSB2OrSlower)
                    if speed.isUSB2OrSlower {
                        note("This cable runs at USB 2 speed. A USB 3 USB-C cable (5 Gb/s or faster) gives Max quality more headroom.")
                    }
                }
                if let battery = model.status.batteryPercent {
                    row("Battery", "\(battery)%", warning: battery <= 15)
                }
            } else {
                Text(model.phase == .searching ? "No camera connected" : "Connecting…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Output")
            labeled("Aspect ratio") {
                Picker("Aspect ratio", selection: $model.aspect) {
                    ForEach(OutputAspect.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            labeled("Live view quality") {
                Picker("Live view quality", selection: $model.quality) {
                    ForEach(LiveViewQuality.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Toggle("Live view", isOn: $model.liveViewEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(model.phase != .connected)
        }
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Performance")
            row("Frames", model.receivingFrames ? String(format: "%.1f fps", model.stats.fps) : "–")
            row("USB → screen", model.stats.usbToScreenMs.map { String(format: "%.0f ms", $0) } ?? "–",
                help: "From a frame arriving over USB to it appearing in the viewfinder.")
            row("Decode", model.receivingFrames ? String(format: "%.1f ms", model.stats.decodeMs) : "–")
            row("USB traffic", model.receivingFrames ? String(format: "%.1f MB/s · %.0f req/s", model.stats.megabytesPerSecond, model.stats.requestRate) : "–")
            if let result = model.latency.lastResult {
                row("Glass to glass", String(format: "%.0f ms", result.medianMs),
                    help: "Median from the last Measure Latency run: screen → camera sensor → USB → Reflex.")
            }
            Button("Measure Latency…") { openWindow(id: "latency") }
                .disabled(!model.receivingFrames)
        }
    }

    // MARK: Building blocks

    private func row(_ label: String, _ value: String, help: String? = nil, warning: Bool = false) -> some View {
        LabeledContent(label) {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(warning ? Theme.warning : .primary)
        }
        .help(help ?? "")
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Picker("Appearance", selection: $model.appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Pace USB requests to the camera's frame rate", isOn: $model.pacing)
            Text("Saves USB bandwidth and lowers delay. Takes effect the next time the camera connects.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .preferredColorScheme(model.appearance.colorScheme)
    }
}
