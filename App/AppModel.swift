import AppKit
import Foundation
import Observation
import ReflexCamera
import ReflexPTP
import ReflexVideo
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox

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
    var gpuMs = 0.0
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
    var isFocusing = false
    var focusMessage: String?
    /// Show the AF box until this time (after a focus action).
    var showAFFrameUntil = Date.distantPast

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
    var outputScale: OutputScale {
        didSet {
            defaults.set(outputScale.rawValue, forKey: "outputScale")
            applyEnhancement()
        }
    }
    var sharpness: Float {
        didSet {
            defaults.set(sharpness, forKey: "sharpness")
            applyEnhancement()
        }
    }
    var upscalerAvailable: Bool { pipeline?.upscalerAvailable ?? false }
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
    /// `--snapshot-dir=<dir>` saves an output frame every 5 s (for comparing settings during development).
    @ObservationIgnored private let snapshotDirectory: URL? = ProcessInfo.processInfo.arguments
        .first { $0.hasPrefix("--snapshot-dir=") }
        .map { URL(filePath: String($0.dropFirst("--snapshot-dir=".count))) }
    @ObservationIgnored private var lastSnapshot = 0.0
    /// `--quick-setup` runs Quick setup once live view is up (for testing without clicking).
    @ObservationIgnored private var pendingQuickSetup = ProcessInfo.processInfo.arguments.contains("--quick-setup")
    @ObservationIgnored private let diagnosticsURL: URL? = ProcessInfo.processInfo.arguments
        .first { $0.hasPrefix("--diagnostics=") }
        .map { URL(filePath: String($0.dropFirst("--diagnostics=".count))) }

    init() {
        aspect = OutputAspect(rawValue: defaults.string(forKey: "aspect") ?? "") ?? .wide
        quality = LiveViewQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .high
        showPanel = defaults.object(forKey: "showPanel") as? Bool ?? true
        exposurePreview = defaults.object(forKey: "exposurePreview") as? Bool ?? true
        outputScale = OutputScale(rawValue: defaults.string(forKey: "outputScale") ?? "") ?? .hd1080
        sharpness = defaults.object(forKey: "sharpness") as? Float ?? 0.35
        // Settings v2: picture-quality defaults (Max JPEG, 1080p enhanced, moderate sharpening) replace v1's.
        if defaults.integer(forKey: "settingsVersion") < 2 {
            quality = .max
            outputScale = .hd1080
            sharpness = 0.35
            defaults.set(2, forKey: "settingsVersion")
        }
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
        applyEnhancement()
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
                          roundTripMs: (usb?.meanRoundTrip ?? 0) * 1000, gpuMs: video.meanGPU * 1000)
        if !receivingFrames { stats.width = pipeline.latestFrame?.width ?? 0; stats.height = pipeline.latestFrame?.height ?? 0 }
        if let diagnosticsURL { writeDiagnostics(video: video, to: diagnosticsURL) }
        if pendingQuickSetup, receivingFrames, !controls.isEmpty {
            pendingQuickSetup = false
            quickSetup()
        }
        if let snapshotDirectory, receivingFrames, hostTime() - lastSnapshot > 5 {
            lastSnapshot = hostTime()
            saveFrame(to: snapshotDirectory)
        }
    }

    private func writeDiagnostics(video: PipelineCounters, to url: URL) {
        let usb = video.usbToScreen.sorted()
        let line: [String: Any] = [
            "t": hostTime(), "phase": "\(phase)", "mode": status.liveViewMode?.rawValue ?? "", "problem": status.problem ?? "",
            "battery": status.batteryPercent ?? -1, "fps": stats.fps, "size": "\(stats.width)x\(stats.height)",
            "usbToScreenMedianMs": stats.usbToScreenMs ?? -1, "usbToScreenP95Ms": usb.isEmpty ? -1 : usb[Int(Double(usb.count - 1) * 0.95)] * 1000,
            "decodeMs": stats.decodeMs, "gpuMs": stats.gpuMs, "scale": outputScale.rawValue, "sharpness": sharpness, "requestRate": stats.requestRate, "repeatRate": stats.repeatRate,
            "MBps": stats.megabytesPerSecond, "rttMs": stats.roundTripMs,
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled, "thermal": ProcessInfo.processInfo.thermalState.rawValue, "dropped": video.dropped, "quality": quality.rawValue,
            "glassToGlassMs": latency.lastResult?.medianMs ?? -1, "exposurePreview": exposurePreview, "focusing": isFocusing, "focusMessage": focusMessage ?? "",
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

    /// Saves the current output frame as a PNG. Returns the file, or nil if there's no frame yet.
    @discardableResult
    func saveFrame(to directory: URL? = nil) -> URL? {
        guard let frame = pipeline?.latestFrame else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(frame.pixelBuffer, options: nil, imageOut: &image)
        guard let image else { return nil }
        let folder = directory ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appending(path: "Reflex")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let url = folder.appending(path: "Reflex \(stamp) \(frame.width)x\(frame.height).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    // MARK: Focus

    /// Live-view JPEG → output-frame mapping for the current aspect crop.
    private func outputCrop() -> (jpeg: CGSize, crop: CropRect)? {
        guard let size = camera?.liveViewSize, size.width > 0 else { return nil }
        return (size, CropRect.centered(sourceWidth: Int(size.width), sourceHeight: Int(size.height), aspect: aspect.ratio))
    }

    /// Focus at a point in the output frame (0…1, top-left origin), or at the current AF area when nil.
    func autofocus(atOutput point: CGPoint? = nil) {
        guard let camera, !isFocusing else { return }
        var target: CGPoint?
        if let point, let (jpeg, crop) = outputCrop() {
            target = CGPoint(x: (Double(crop.x) + point.x * Double(crop.width)) / jpeg.width,
                             y: (Double(crop.y) + point.y * Double(crop.height)) / jpeg.height)
        }
        isFocusing = true
        focusMessage = nil
        showAFFrameUntil = .distantFuture
        Task {
            do {
                if try await camera.autofocus(at: target) == .couldNotLock {
                    focusMessage = "Couldn't lock focus there. Click something with more detail, or add light."
                }
            } catch {
                focusMessage = "\(error)"
            }
            isFocusing = false
            showAFFrameUntil = Date().addingTimeInterval(1.5)
        }
    }

    /// The AF area in output-frame coordinates (0…1), if it's inside the visible crop.
    var afFrameInOutput: CGRect? {
        guard let af = status.afFrame, let (jpeg, crop) = outputCrop() else { return nil }
        let rect = CGRect(x: (af.minX * jpeg.width - Double(crop.x)) / Double(crop.width),
                          y: (af.minY * jpeg.height - Double(crop.y)) / Double(crop.height),
                          width: af.width * jpeg.width / Double(crop.width),
                          height: af.height * jpeg.height / Double(crop.height))
        return rect.intersects(CGRect(x: 0, y: 0, width: 1, height: 1)) ? rect : nil
    }

    // MARK: Quick setup

    /// A good starting point for streaming indoors: f/2.8 (or the lens's widest if it can't open that far),
    /// 1/60 s (1/50 in 50 Hz countries, so lights don't flicker), Auto ISO, no compensation, then autofocus.
    func quickSetup() {
        guard let camera else { return }
        let controls = controls
        func state(_ c: CameraControl) -> ControlState? { controls.first { $0.control == c && $0.isWritable } }
        Task {
            if let aperture = state(.aperture),
               let best = aperture.options.min(by: { abs(log(Double($0.int ?? 1) / 280)) < abs(log(Double($1.int ?? 1) / 280)) }) {
                try? await camera.set(.aperture, to: best)
            }
            if let shutter = state(.shutter) {
                let target = 1 / Self.mainsFrequency
                let seconds: (PTPValue) -> Double = { value in
                    let v = Double(value.int ?? 0)
                    return shutter.mode == .photo ? v / 10_000 : Double((value.int ?? 0) >> 16) / Double(max((value.int ?? 1) & 0xFFFF, 1))
                }
                if let best = shutter.options.filter({ seconds($0) > 0 }).min(by: { abs(log(seconds($0) / target)) < abs(log(seconds($1) / target)) }) {
                    try? await camera.set(.shutter, to: best)
                }
            }
            if state(.autoISO) != nil { try? await camera.set(.autoISO, to: .unsigned(1)) }
            if state(.compensation) != nil { try? await camera.set(.compensation, to: .signed(0)) }
            autofocus()
        }
    }

    /// Mains frequency for flicker-free shutter speeds.
    static var mainsFrequency: Double {
        let sixtyHertz: Set<String> = ["US", "CA", "MX", "BR", "CO", "VE", "PE", "EC", "KR", "TW", "PH", "SA", "PR", "CR",
                                       "GT", "HN", "NI", "PA", "SV", "DO", "BS", "JM", "TT", "CU", "LR"]
        return sixtyHertz.contains(Locale.current.region?.identifier ?? "") ? 60 : 50
    }

    private func applyEnhancement() { pipeline?.setEnhancement(scale: outputScale, sharpness: sharpness) }

    func toggleLiveView() { liveViewEnabled.toggle() }

    func setControl(_ control: CameraControl, to value: PTPValue) {
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
