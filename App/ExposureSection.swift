import ReflexCamera
import ReflexPTP
import SwiftUI

/// Exposure controls built from what the camera reports: only values the body accepts right now, and read-only
/// when the mode dial owns the setting.
struct ExposureSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Exposure")
            if model.controls.isEmpty {
                Text(model.phase == .connected ? "Reading camera settings…" : "Connect the camera to adjust exposure.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.controls) { state in
                    switch state.control {
                    case .mode:
                        LabeledContent("Mode") { Text(state.label).monospacedDigit() }
                            .help("Set with the mode dial on the camera.")
                    case .autoISO:
                        Toggle("Auto ISO", isOn: Binding(
                            get: { state.value.int == 1 },
                            set: { model.setControl(.autoISO, to: .unsigned($0 ? 1 : 0)) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!state.isWritable)
                    default:
                        StepSlider(state: state) { model.setControl(state.control, to: $0) }
                    }
                }
                if model.status.liveViewMode == .photo {
                    Toggle("Exposure preview", isOn: $model.exposurePreview)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text(model.exposurePreview
                         ? "The picture follows these settings. Too dark? Open the aperture (smaller f-number), raise ISO or turn on Auto ISO."
                         : "The camera brightens the picture itself, but slows live view in dim light (about 15 fps).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A slider over a control's discrete camera values, with − / + for single steps. Applies on release.
struct StepSlider: View {
    let state: ControlState
    let apply: (PTPValue) -> Void
    @State private var dragIndex: Double?

    private var count: Int { state.options.count }
    private var currentIndex: Double { Double(state.index ?? 0) }
    private var shownIndex: Int { Int((dragIndex ?? currentIndex).rounded()) }
    private var adjustable: Bool { state.isWritable && count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(state.control.title).foregroundStyle(.secondary)
                Spacer()
                Text(state.label(for: state.options[min(max(shownIndex, 0), count - 1)]))
                    .monospacedDigit()
                    .foregroundStyle(adjustable ? .primary : .secondary)
            }
            if adjustable {
                HStack(spacing: 6) {
                    stepButton("minus", by: -1)
                    Slider(value: Binding(get: { dragIndex ?? currentIndex }, set: { dragIndex = $0 }),
                           in: 0...Double(count - 1), step: 1) { editing in
                        if !editing, let dragIndex { commit(Int(dragIndex.rounded())) }
                    }
                    .labelsHidden()
                    stepButton("plus", by: 1)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.control.title)
        .accessibilityValue(state.label)
        .help(adjustable ? "" : "Not adjustable in the camera's current mode (set by the mode dial).")
        .onChange(of: state.value) { _, _ in dragIndex = nil }
    }

    private func stepButton(_ symbol: String, by delta: Int) -> some View {
        Button {
            commit(Int(currentIndex) + delta)
        } label: {
            Image(systemName: symbol).frame(width: 14, height: 14)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(delta < 0 ? "Decrease \(state.control.title)" : "Increase \(state.control.title)")
        .disabled(delta < 0 ? currentIndex <= 0 : currentIndex >= Double(count - 1))
    }

    private func commit(_ index: Int) {
        let clamped = min(max(index, 0), count - 1)
        guard state.options[clamped] != state.value else { dragIndex = nil; return }
        apply(state.options[clamped])
    }
}
