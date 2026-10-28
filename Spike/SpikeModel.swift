import AppKit
import Foundation
import Observation
import QuartzCore
import ReflexPTP

/// Launch options: `--out=<dir> --auto=probe,lv,bench,setting,decode,soak,latency,stop --bench-seconds=5 --quit`
struct LaunchOptions {
    var outDir: URL
    var auto: [String] = []
    var benchSeconds = 5.0
    var soakSeconds = 30.0
    var latencyTrials = 20
    var quit = false

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        outDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Desktop/Coding/Reflex/spike-output/\(stamp)")
        for arg in arguments.dropFirst() {
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "--out": outDir = URL(filePath: (value as NSString).expandingTildeInPath)
            case "--auto": auto = value.split(separator: ",").map(String.init)
            case "--bench-seconds": benchSeconds = Double(value) ?? benchSeconds
            case "--soak-seconds": soakSeconds = Double(value) ?? soakSeconds
            case "--latency-trials": latencyTrials = Int(value) ?? latencyTrials
            case "--quit": quit = true
            default: break
            }
        }
    }
}

/// Puts decoded frames on a CALayer directly (no SwiftUI diffing per frame).
nonisolated final class PreviewLayer: @unchecked Sendable {
    let layer: CALayer = {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }()

    func show(_ image: CGImage) {
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer.contents = image
            CATransaction.commit()
        }
    }
}

@Observable
final class SpikeModel {
    var status = "Waiting for a camera…"
    var cameraName: String?
    var logLines: [String] = []
    var snapshot: LiveStats.Snapshot?
    var lastLuma = 0.0
    var liveViewRunning = false
    var activity: String?
    var latencyWindowRequested = false

    let options = LaunchOptions()
    let preview = PreviewLayer()
    let latencyTarget = LatencyTarget()
    @ObservationIgnored private let latencyTest = LatencyTest()
    @ObservationIgnored private var discovery: CameraDiscovery?
    @ObservationIgnored private var session: CameraSession?
    @ObservationIgnored private var decoder: FrameDecoder?
    @ObservationIgnored private var statsTimer: Timer?
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var lastProbe: CameraSession.ProbeResult?
    @ObservationIgnored private var summary: [String] = []
    @ObservationIgnored private var recentEvents: [String] = []

    var outDir: URL { options.outDir }
    var hasCamera: Bool { session != nil }

    func launch() {
        guard !launched else { return }
        launched = true
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        log("Output folder: \(outDir.path)")
        let discovery = CameraDiscovery { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.discovery = discovery
        discovery.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
        if !options.auto.isEmpty {
            Task { await runAuto(options.auto) }
        }
    }

    private func handle(_ event: CameraDiscovery.Event) {
        switch event {
        case let .connected(connection):
            cameraName = connection.name
            status = "Connected: \(connection.name)"
            log(String(format: "Session open: %@ (USB %04x:%04x), PTP passthrough %@", connection.name,
                       connection.usbVendorID, connection.usbProductID, connection.supportsPTPPassthrough ? "yes" : "NO"))
            let session = CameraSession(connection: connection) { [weak self] line in
                Task { @MainActor in self?.log(line) }
            }
            let stats = session.stats
            let decoder = FrameDecoder { [weak self, preview] decoded in
                stats.decoded(seconds: decoded.decodeSeconds)
                preview.show(decoded.image)
                Task { @MainActor in
                    self?.latencyTest.feed(decoded)
                    self?.lastLuma = decoded.meanLuma
                }
            }
            session.onFrame { decoder.submit($0) }
            session.onEvents { [weak self] events in
                let text = events.map { "\($0.code.name ?? $0.code.hex)(\($0.params.map { String(format: "0x%04X", $0) }.joined(separator: ",")))" }
                Task { @MainActor in
                    self?.recentEvents.append(contentsOf: text)
                    self?.log("Events: " + text.joined(separator: " "))
                }
            }
            connection.onPTPEvent = { [weak self] data in
                let text = (try? PTPEvent.decodeContainer(data)).map { "\($0.code) \($0.params)" } ?? "\(data.count) bytes"
                Task { @MainActor in self?.log("Interrupt event: \(text)") }
            }
            self.session = session
            self.decoder = decoder
        case let .disconnected(connection):
            log("Disconnected: \(connection.name)")
            status = "Waiting for a camera…"
            cameraName = nil
            session = nil
            decoder = nil
            liveViewRunning = false
        case let .failed(message):
            log(message)
            status = message
        }
    }

    private func refreshStats() {
        guard let session else { return }
        liveViewRunning = session.isLiveViewRunning
        if liveViewRunning { snapshot = session.stats.snapshot() }
    }

    func log(_ line: String) {
        let stamp = String(format: "%8.3f", hostTime().truncatingRemainder(dividingBy: 100_000))
        let entry = "[\(stamp)] \(line)"
        print(entry)
        logLines.append(entry)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
        let url = outDir.appending(path: "log.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((entry + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((entry + "\n").utf8).write(to: url)
        }
    }

    // MARK: Steps

    func probe() async {
        guard let session else { return log("No camera") }
        activity = "Probing…"
        defer { activity = nil }
        do {
            let result = try await session.probe()
            lastProbe = result
            let report = ProbeReport(result, connection: session.connection)
            ReportWriter.write(report, to: outDir.appending(path: "probe.json"))
            let writable = result.descriptors.values.filter(\.isWritable).count
            let line = String(format: "Probe: %@ %@ fw %@, %d ops, %d props (%d writable, %d vendor-only), %d failed, %.2f s",
                              result.info.manufacturer, result.info.model, result.info.deviceVersion,
                              result.info.operations.count, result.descriptors.count, writable,
                              report.vendorOnlyProperties.count, result.failures.count, result.seconds)
            log(line)
            summary.append("- " + line)
            for op in [PTPOperationCode.nikonStartLiveView, .nikonGetLiveViewImage, .nikonGetLiveViewImageEx,
                       .nikonChangeAfArea, .nikonMfDrive, .nikonAfDrive, .nikonGetEvent, .nikonGetEventEx] {
                log("  \(op): \(result.info.supports(op) ? "supported" : "not listed")")
            }
        } catch {
            log("Probe failed: \(error)")
        }
    }

    func startLiveView() {
        guard let session else { return log("No camera") }
        session.stats.reset()
        session.startLiveView()
        liveViewRunning = true
    }

    func stopLiveView() async {
        guard let session else { return }
        await session.stopLiveView()
        liveViewRunning = false
    }

    private func waitForFrames(timeout: Double = 5) async -> Bool {
        guard let session else { return false }
        let deadline = hostTime() + timeout
        while hostTime() < deadline {
            if session.stats.snapshot().uniqueFrames > 2 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func benchmark() async {
        guard let session else { return log("No camera") }
        activity = "Benchmarking live-view sizes…"
        defer { activity = nil }
        if !session.isLiveViewRunning { startLiveView() }
        guard await waitForFrames() else { return log("Benchmark: no frames arriving") }

        let transport = session.transport
        var context: [String: String] = [:]
        for (code, type) in [(PTPPropertyCode.nikonLiveViewSelector, PTPDataType.uint8), (.exposureProgramMode, .uint16),
                             (.nikonLiveViewImageZoomRatio, .uint8), (.nikonLiveViewImageCompression, .uint8)] {
            if let v = try? await transport.propertyValue(code, type: type) { context[code.description] = v.description }
        }
        let sizeDesc = try? await transport.propertyDescriptor(.nikonLiveViewImageSize)
        var values: [PTPValue?] = [nil]
        if let sizeDesc, sizeDesc.isWritable, let allowed = sizeDesc.allowedValues, !allowed.isEmpty {
            values = allowed
            context["LiveViewImageSize.current"] = sizeDesc.current.description
        } else {
            log("LiveViewImageSize not writable/supported; benchmarking the current size only")
        }

        var rows: [BenchmarkReport.Row] = []
        for value in values {
            var label = "current"
            if let value, let sizeDesc {
                label = value.description
                if !(await setLiveViewSize(value, type: sizeDesc.dataType, session: session)) { continue }
            }
            try? await Task.sleep(for: .milliseconds(800))
            session.stats.reset()
            saveSamples(label: "size\(label)", count: 3)
            try? await Task.sleep(for: .seconds(options.benchSeconds))
            let snap = session.stats.snapshot()
            rows.append(.init(liveViewImageSize: label, stats: snap))
            let line = String(format: "Bench size %@: %dx%d, %.1f fps unique (%.1f req/s, %d busy, %d dup), RTT p50 %.1f / p95 %.1f ms, %.0f KB/frame, %.1f MB/s, decode %.2f ms, jitter σ %.1f ms",
                              label, snap.width, snap.height, snap.uniqueFPS, snap.requestRate, snap.busyResponses,
                              snap.duplicateFrames, snap.rttP50Ms, snap.rttP95Ms, snap.payloadMeanKB, snap.throughputMBps,
                              snap.decodeMeanMs, snap.intervalStdDevMs)
            log(line)
            summary.append("- " + line)
        }
        if let sizeDesc, values.count > 1 {
            _ = await setLiveViewSize(sizeDesc.current, type: sizeDesc.dataType, session: session)
        }
        ReportWriter.write(BenchmarkReport(context: context, rows: rows), to: outDir.appending(path: "bench.json"))
        log("Bench context: \(context)")
    }

    private func setLiveViewSize(_ value: PTPValue, type: PTPDataType, session: CameraSession) async -> Bool {
        do {
            try await session.transport.setPropertyValue(.nikonLiveViewImageSize, value, type: type)
            return true
        } catch {
            log("Setting LiveViewImageSize=\(value) during live view failed (\(error)); retrying with live view off")
            await session.stopLiveView()
            do {
                try await session.transport.setPropertyValue(.nikonLiveViewImageSize, value, type: type)
            } catch {
                log("LiveViewImageSize=\(value) rejected: \(error)")
                session.startLiveView()
                return false
            }
            session.stats.reset()
            session.startLiveView()
            return await waitForFrames()
        }
    }

    func soak() async {
        guard let session else { return }
        activity = "Soak test…"
        defer { activity = nil }
        if !session.isLiveViewRunning { startLiveView() }
        guard await waitForFrames() else { return log("Soak: no frames") }
        session.stats.reset()
        try? await Task.sleep(for: .seconds(options.soakSeconds))
        let snap = session.stats.snapshot()
        ReportWriter.write(snap, to: outDir.appending(path: "soak.json"))
        let line = String(format: "Soak %.0f s: %.2f fps unique, interval mean %.1f / p95 %.1f ms (σ %.1f), RTT p95 %.1f / max %.1f ms, %d bad, %d busy, decoder dropped %d",
                          snap.seconds, snap.uniqueFPS, snap.intervalMeanMs, snap.intervalP95Ms, snap.intervalStdDevMs,
                          snap.rttP95Ms, snap.rttMaxMs, snap.badFrames, snap.busyResponses, decoder?.dropped ?? 0)
        log(line)
        summary.append("- " + line)
    }

    /// Changes white balance and exposure compensation during live view, reads them back, restores them.
    func settingTest() async {
        guard let session else { return log("No camera") }
        activity = "Changing settings…"
        defer { activity = nil }
        if !session.isLiveViewRunning { startLiveView() }
        _ = await waitForFrames()
        let transport = session.transport
        var rows: [SettingTestReport.Row] = []

        for code in [PTPPropertyCode.whiteBalance, .exposureBiasCompensation] {
            var row = SettingTestReport.Row(property: code.description, before: "?", target: "?", applied: false,
                                            restored: false, liveViewKeptRunning: false, eventsSeen: [])
            do {
                let desc = try await transport.propertyDescriptor(code)
                row.before = desc.current.description
                guard desc.isWritable, let target = desc.allowedValues?.first(where: { $0 != desc.current && pickable($0, code) }) else {
                    row.error = "not writable or no alternative value"
                    rows.append(row)
                    continue
                }
                row.target = target.description
                recentEvents.removeAll()
                let framesBefore = session.stats.snapshot().uniqueFrames
                let set = try await transport.setPropertyValue(code, target, type: desc.dataType)
                row.setRoundTripMs = set.roundTrip * 1000
                let readBack = try await transport.propertyValue(code, type: desc.dataType)
                row.readBack = readBack.description
                row.applied = readBack == target
                try? await Task.sleep(for: .seconds(2))
                row.liveViewKeptRunning = session.stats.snapshot().uniqueFrames > framesBefore + 10
                row.eventsSeen = recentEvents
                try await transport.setPropertyValue(code, desc.current, type: desc.dataType)
                row.restored = (try await transport.propertyValue(code, type: desc.dataType)) == desc.current
            } catch {
                row.error = "\(error)"
            }
            log("Setting \(row.property): \(row.before) → \(row.target), applied \(row.applied), set RTT \(row.setRoundTripMs.map { String(format: "%.1f ms", $0) } ?? "-"), LV kept running \(row.liveViewKeptRunning), events \(row.eventsSeen), restored \(row.restored)\(row.error.map { ", error \($0)" } ?? "")")
            rows.append(row)
        }
        ReportWriter.write(SettingTestReport(rows: rows), to: outDir.appending(path: "settings.json"))
        summary.append("- Settings: " + rows.map { "\($0.property) applied=\($0.applied) rtt=\($0.setRoundTripMs.map { String(format: "%.1fms", $0) } ?? "-") lv=\($0.liveViewKeptRunning)" }.joined(separator: "; "))
    }

    /// Prefer visibly different values: tungsten-ish white balance, +1 EV.
    private func pickable(_ value: PTPValue, _ code: PTPPropertyCode) -> Bool {
        switch code {
        case .whiteBalance: return value.int == 6 || value.int == 4 || value.int == 0x8010
        case .exposureBiasCompensation: return value.int == 1000 || value.int == -1000
        default: return true
        }
    }

    func decodeBenchmark() {
        let samples = outDir.appending(path: "samples")
        guard let file = try? FileManager.default.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "jpg" }).sorted(by: { $0.path < $1.path }).last,
              let jpeg = try? Data(contentsOf: file) else {
            return log("Decode benchmark: no sample JPEGs yet (run the size benchmark first)")
        }
        activity = "Decode benchmark…"
        let result = DecodeBenchmark.run(jpeg: jpeg)
        activity = nil
        ReportWriter.write(result, to: outDir.appending(path: "decode.json"))
        for row in result.rows {
            let line = String(format: "Decode %@ (%dx%d, %.0f KB): mean %.2f ms, p95 %.2f ms, hw %@ %@", row.method,
                              result.width, result.height, result.jpegKB, row.meanMs, row.p95Ms,
                              row.hardwareAccelerated.map { $0 ? "yes" : "no" } ?? "n/a", row.note ?? "")
            log(line)
            summary.append("- " + line)
        }
    }

    func latency() async {
        guard let session else { return log("No camera") }
        latencyWindowRequested = true
        activity = "Latency test — point the camera at the Latency Target window"
        defer { activity = nil }
        if !session.isLiveViewRunning { startLiveView() }
        guard await waitForFrames() else { return log("Latency: no frames") }
        try? await Task.sleep(for: .seconds(1))
        guard let result = await latencyTest.run(target: latencyTarget, trials: options.latencyTrials, log: { log($0) }) else { return }
        ReportWriter.write(result, to: outDir.appending(path: "latency.json"))
        let line = String(format: "Latency (glass-to-host, %d trials, %d timeouts): median %.0f ms, min %.0f, p90 %.0f, max %.0f; +decode median %.0f ms",
                          result.trials.count, result.timeouts, result.medianMs, result.minMs, result.p90Ms,
                          result.maxMs, result.medianDecodedMs)
        log(line)
        summary.append("- " + line)
    }

    private func saveSamples(label: String, count: Int) {
        guard let session else { return }
        let dir = outDir.appending(path: "samples")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let counter = Counter()
        session.setSampleSink { [weak session] frame in
            let n = counter.next()
            guard n <= count else { session?.setSampleSink(nil); return }
            try? frame.frame.payload.write(to: dir.appending(path: "\(label)_\(n).bin"))
            try? frame.frame.jpeg.write(to: dir.appending(path: "\(label)_\(n).jpg"))
        }
    }

    func runAuto(_ steps: [String]) async {
        log("Auto steps: \(steps.joined(separator: ", "))")
        let deadline = hostTime() + 120
        let needsCamera = steps.contains { $0 != "decode" }
        while needsCamera, session == nil, hostTime() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
        guard session != nil || !needsCamera else {
            log("No camera within 120 s")
            if options.quit { NSApp.terminate(nil) }
            return
        }
        try? await Task.sleep(for: .milliseconds(500))
        for step in steps {
            switch step {
            case "probe": await probe()
            case "lv":
                startLiveView()
                _ = await waitForFrames()
            case "bench": await benchmark()
            case "setting": await settingTest()
            case "decode": decodeBenchmark()
            case "soak": await soak()
            case "latency": await latency()
            case "stop": await stopLiveView()
            default: log("Unknown step \(step)")
            }
        }
        let text = "# Spike run \(outDir.lastPathComponent)\n\n" + summary.joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: outDir.appending(path: "summary.md"))
        log("Auto run finished")
        if options.quit {
            if session?.isLiveViewRunning == true { await stopLiveView() }
            NSApp.terminate(nil)
        }
    }
}

nonisolated private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
