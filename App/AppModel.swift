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
    var showPanel: Bool {
        didSet { defaults.set(showPanel, forKey: "showPanel") }
    }
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    /// Pace USB requests to the camera's frame clock (Settings → Advanced; on by default).
    var pacing: Bool {
        didSet { defaults.set(pacing, forKey: "pacing") }
    }

    let pipeline: VideoPipeline?
    let viewfinder: ViewfinderRenderer?
    let latency: LatencyTestController

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var discovery: CameraDiscovery?
    @ObservationIgnored private var camera: NikonCamera?
    @ObservationIgnored private var statsTimer: Timer?

    init() {
        aspect = OutputAspect(rawValue: defaults.string(forKey: "aspect") ?? "") ?? .wide
        quality = LiveViewQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .high
        showPanel = defaults.object(forKey: "showPanel") as? Bool ?? true
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .dark
        pacing = defaults.object(forKey: "pacing") as? Bool ?? true
        if let forced = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--pacing=") }) {
            pacing = forced == "--pacing=on"
        }

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
            let camera = NikonCamera(connection: connection, quality: quality, pacing: pacing)
            let pipeline = pipeline
            camera.onFrame { live in
                guard let width = live.info?.jpegWidth ?? live.frame.jpegDimensions?.width,
                      let height = live.info?.jpegHeight ?? live.frame.jpegDimensions?.height else { return }
                pipeline?.submit(CompressedFrame(jpeg: live.frame.jpeg, width: width, height: height,
                                                 sequence: live.sequence, requestedAt: live.requestedAt,
                                                 arrivedAt: live.arrivedAt))
            }
            camera.onStatus { [weak self] status in
                Task { @MainActor in self?.status = status }
            }
            self.camera = camera
            Task {
                do {
                    identity = try await camera.prepare()
                    status = camera.currentStatus
                    phase = .connected
                    camera.setLiveViewEnabled(liveViewEnabled)
                    camera.start()
                } catch {
                    phase = .failed("\(error)")
                }
            }
        case let .disconnected(connection):
            guard camera?.connection === connection else { return }
            camera = nil
            identity = nil
            status = CameraStatus()
            phase = .searching
        case let .failed(message):
            phase = .failed(message)
        }
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
                          megabytesPerSecond: usb?.megabytesPerSecond ?? 0)
        if !receivingFrames { stats.width = pipeline.latestFrame?.width ?? 0; stats.height = pipeline.latestFrame?.height ?? 0 }
    }

    func toggleLiveView() { liveViewEnabled.toggle() }

    /// Stops live view and restores the camera settings Reflex changed. Called on quit.
    func shutdown() async {
        statsTimer?.invalidate()
        await camera?.shutdown()
        discovery?.stop()
    }
}
