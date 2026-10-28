import AppKit
import Foundation
import Observation
import ReflexCamera
import ReflexPTP
import ReflexVideo
import SwiftUI

enum OutputAspect: String, CaseIterable, Identifiable {
    case wide, classic

    var id: String { rawValue }
    var label: String { self == .wide ? "16:9" : "3:2" }
    var ratio: Double { self == .wide ? 16.0 / 9.0 : 3.0 / 2.0 }
}

enum Appearance: String, CaseIterable, Identifiable {
    case dark, light, system

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

/// Live numbers for the status bar, refreshed twice a second.
struct LiveStats: Equatable {
    var fps = 0.0
    var width = 0
    var height = 0
    var usbToScreenMs: Double?
    var decodeMs = 0.0
    var requestRate = 0.0
    var repeatRate = 0.0
    var megabytesPerSecond = 0.0
    var roundTripMs = 0.0
}

@Observable
final class AppModel {
    enum Phase: Equatable {
        case searching
        case connecting(String)
        case connected
        case failed(String)
    }

    var phase: Phase = .searching
    var identity: CameraIdentity?
    var status = CameraStatus()
    var stats = LiveStats()
    var receivingFrames = false
    var setupError: String?
    var controls: [ControlState] = []

    var aspect: OutputAspect {
        didSet {
            defaults.set(aspect.rawValue, forKey: "aspect")
            pipeline?.setAspect(aspect.ratio)
        }
    }
    var quality: LiveViewQuality {
        didSet {
            defaults.set(quality.rawValue, forKey: "quality")
            camera?.setQuality(quality)
        }
    }
    var liveViewEnabled = true {
        didSet { camera?.setLiveViewEnabled(liveViewEnabled) }
    }
    /// Exposure preview in photo live view (on: image follows settings at 30 fps; off: camera auto-brightens).
    var exposurePreview: Bool {
        didSet {
            defaults.set(exposurePreview, forKey: "exposurePreview")
            camera?.setExposurePreview(exposurePreview)
        }
    }
    var showPanel: Bool {
        didSet { defaults.set(showPanel, forKey: "showPanel") }
    }
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }

    let pipeline: VideoPipeline?
    let viewfinder: ViewfinderRenderer?
    let latency: LatencyTestController

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var discovery: CameraDiscovery?
    @ObservationIgnored private var camera: NikonCamera?
    @ObservationIgnored private var statsTimer: Timer?
    /// `--diagnostics=<file>` appends one JSON line of stats per tick (for testing without the UI).
    @ObservationIgnored private let diagnosticsURL: URL? = ProcessInfo.processInfo.arguments
        .first { $0.hasPrefix("--diagnostics=") }
        .map { URL(filePath: String($0.dropFirst("--diagnostics=".count))) }

    init() {
        aspect = OutputAspect(rawValue: defaults.string(forKey: "aspect") ?? "") ?? .wide
        quality = LiveViewQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .high
        showPanel = defaults.object(forKey: "showPanel") as? Bool ?? true
        exposurePreview = defaults.object(forKey: "exposurePreview") as? Bool ?? true
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .dark

        var pipeline: VideoPipeline?
        var viewfinder: ViewfinderRenderer?
        do {
            let metal = try MetalContext()
            let p = try VideoPipeline(metal: metal)
            let v = try ViewfinderRenderer(metal: metal) { [weak p] frame, presentedAt in
                p?.recordPresentation(of: frame, at: presentedAt)
            }
            p.add(v)
            pipeline = p
            viewfinder = v
        } catch {
            setupError = "Metal is unavailable: \(error)"
        }
        self.pipeline = pipeline
        self.viewfinder = viewfinder
        latency = LatencyTestController(pipeline: pipeline)
        pipeline?.setAspect(aspect.ratio)
        start()
    }

    private func start() {
        let discovery = CameraDiscovery { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.discovery = discovery
        discovery.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
    }

    private func handle(_ event: CameraDiscovery.Event) {
        switch event {
        case let .connected(connection):
            guard camera == nil else { return }
            phase = .connecting(connection.name)
            let camera = NikonCamera(connection: connection, quality: quality, exposurePreview: exposurePreview)
            let pipeline = pipeline
            camera.onFrame { live in
                guard let width = live.info?.jpegWidth ?? live.frame.jpegDimensions?.width,
                      let height = live.info?.jpegHeight ?? live.frame.jpegDimensions?.height else { return }
                pipeline?.submit(CompressedFrame(jpeg: live.frame.jpeg, width: width, height: height,
                                                 sequence: live.sequence, requestedAt: live.requestedAt,
                                                 arrivedAt: live.arrivedAt))
            }
            let diagnostics = diagnosticsURL
            camera.onLog { message in
                guard let diagnostics else { return }
                Self.appendLine(["t": hostTime(), "log": message], to: diagnostics)
            }
            camera.onControls { [weak self] controls in
                Task { @MainActor in self?.controls = controls }
            }
            camera.onStatus { [weak self] status in
                Task { @MainActor in self?.status = status }
            }
            self.camera = camera
            prepare(camera)
        case let .disconnected(connection):
            guard camera?.connection === connection else { return }
            camera = nil
            identity = nil
            controls = []
            status = CameraStatus()
            phase = .searching
        case let .failed(message):
            phase = .failed(message)
        }
    }

    /// Reads the camera's identity and starts live view. A timeout usually means macOS is still cataloging a big
    /// memory card, so it's retried once before giving up.
    private func prepare(_ camera: NikonCamera) {
        phase = .connecting(camera.connection.name)
        Task {
            for attempt in 1...2 {
                do {
                    identity = try await camera.prepare()
                    guard self.camera === camera else { return }
                    status = camera.currentStatus
                    phase = .connected
                    camera.setLiveViewEnabled(liveViewEnabled)
                    camera.start()
                    return
                } catch PTPError.timedOut where attempt < 2 {
                    continue
                } catch PTPError.disconnected {
                    return // the disconnect event resets the state
                } catch PTPError.timedOut {
                    break
                } catch {
                    if self.camera === camera { phase = .failed("\(error)") }
                    return
                }
            }
            if self.camera === camera {
                phase = .failed("The camera didn't answer. Switch it off and on again, or reconnect the USB cable.")
            }
        }
    }

    /// "Try Again" after a failed connection.
    func retryConnection() {
        if let camera { prepare(camera) }
    }

    private func refreshStats() {
        guard let pipeline else { return }
        let video = pipeline.takeCounters()
        let usb = camera?.takeCounters()
        receivingFrames = video.presented > 0
        stats = LiveStats(fps: video.presentedFPS, width: video.lastSize.width, height: video.lastSize.height,
                          usbToScreenMs: video.medianUSBToScreen.map { $0 * 1000 }, decodeMs: video.meanDecode * 1000,
                          requestRate: usb?.requestRate ?? 0,
                          repeatRate: usb.map { Double($0.repeats) / $0.seconds } ?? 0,
                          megabytesPerSecond: usb?.megabytesPerSecond ?? 0,
                          roundTripMs: (usb?.meanRoundTrip ?? 0) * 1000)
        if !receivingFrames { stats.width = pipeline.latestFrame?.width ?? 0; stats.height = pipeline.latestFrame?.height ?? 0 }
        if let diagnosticsURL { writeDiagnostics(video: video, to: diagnosticsURL) }
    }

    private func writeDiagnostics(video: PipelineCounters, to url: URL) {
        let usb = video.usbToScreen.sorted()
        let line: [String: Any] = [
            "t": hostTime(), "phase": "\(phase)", "mode": status.liveViewMode?.rawValue ?? "", "problem": status.problem ?? "",
            "battery": status.batteryPercent ?? -1, "fps": stats.fps, "size": "\(stats.width)x\(stats.height)",
            "usbToScreenMedianMs": stats.usbToScreenMs ?? -1, "usbToScreenP95Ms": usb.isEmpty ? -1 : usb[Int(Double(usb.count - 1) * 0.95)] * 1000,
            "decodeMs": stats.decodeMs, "requestRate": stats.requestRate, "repeatRate": stats.repeatRate,
            "MBps": stats.megabytesPerSecond, "rttMs": stats.roundTripMs,
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled, "thermal": ProcessInfo.processInfo.thermalState.rawValue, "dropped": video.dropped, "quality": quality.rawValue,
            "glassToGlassMs": latency.lastResult?.medianMs ?? -1, "exposurePreview": exposurePreview,
            "controls": controls.map { "\($0.control.rawValue)=\($0.label)\($0.isWritable ? "" : " (ro)") [\($0.options.count)]" },
        ]
        Self.appendLine(line, to: url)
    }

    nonisolated private static func appendLine(_ line: [String: Any], to url: URL) {
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    func toggleLiveView() { liveViewEnabled.toggle() }

    func setControl(_ control: ExposureControl, to value: PTPValue) {
        guard let camera else { return }
        Task { try? await camera.set(control, to: value) }
    }

    /// Stops live view and restores the camera settings Reflex changed. Called on quit.
    func shutdown() async {
        statsTimer?.invalidate()
        await camera?.shutdown()
        discovery?.stop()
    }
}
