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
        discovery.debug = { [weak self] line in Task { @MainActor in self?.log(line) } }
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
                    self?.probes.append((decoded.decodedAt, decoded.meanLuma, decoded.redBlueRatio))
                    if (self?.probes.count ?? 0) > 300 { self?.probes.removeFirst() }
                }
            }
            let latest = latestFrame
            session.onFrame { frame in
                latest.set(frame)
                decoder.submit(frame)
            }
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

    /// Sets `property` to each value in turn during live view, measures, and restores the original.
    private func sweep(_ name: String, property: PTPPropertyCode, values: [PTPValue],
                       label: (PTPValue) -> String, settle: Double = 1.5) async {
        guard let session else { return log("No camera") }
        activity = "Sweep: \(name)…"
        defer { activity = nil }
        if !session.isLiveViewRunning { startLiveView() }
        guard await waitForFrames() else { return log("\(name): no frames") }
        let transport = session.transport
        guard let desc = try? await transport.propertyDescriptor(property) else { return log("\(name): \(property) unsupported") }
        _ = try? await transport.setPropertyValue(.nikonLiveViewImageSize, .unsigned(3), type: .uint8)

        var rows: [BenchmarkReport.Row] = []
        for value in values {
            do {
                try await transport.setPropertyValue(property, value, type: desc.dataType)
            } catch {
                log("\(name) \(label(value)): set failed during live view (\(error)); retrying with live view off")
                await session.stopLiveView()
                do { try await transport.setPropertyValue(property, value, type: desc.dataType) }
                catch { log("\(name) \(label(value)): rejected (\(error))"); session.startLiveView(); continue }
                session.startLiveView()
            }
            try? await Task.sleep(for: .seconds(settle))
            if !session.isLiveViewRunning { session.startLiveView(); _ = await waitForFrames() }
            session.stats.reset()
            saveSamples(label: "\(name)-\(label(value))", count: 2)
            try? await Task.sleep(for: .seconds(options.benchSeconds))
            let s = session.stats.snapshot()
            rows.append(.init(liveViewImageSize: label(value), stats: s))
            let line = String(format: "%@ %@: %dx%d, %.1f fps unique, RTT p50 %.1f / p95 %.1f ms, %.1f KB/frame, %.1f MB/s, decode %.2f ms",
                              name, label(value), s.width, s.height, s.uniqueFPS, s.rttP50Ms, s.rttP95Ms,
                              s.payloadMeanKB, s.throughputMBps, s.decodeMeanMs)
            log(line)
            summary.append("- " + line)
        }
        do {
            try await transport.setPropertyValue(property, desc.current, type: desc.dataType)
            log("\(name): restored \(property) to \(desc.current)")
        } catch {
            log("\(name): could not restore \(property) to \(desc.current): \(error)")
        }
        ReportWriter.write(BenchmarkReport(context: ["property": property.description], rows: rows),
                           to: outDir.appending(path: "sweep-\(name).json"))
    }

    /// Nikon MovScreenSize (0xD0A0) packs width, height and frame rate into a UINT64.
    static func movieModeLabel(_ v: PTPValue) -> String {
        guard case let .unsigned(raw) = v else { return v.description }
        return "\(raw >> 48 & 0xFFFF)x\(raw >> 32 & 0xFFFF)p\(raw >> 16 & 0xFFFF)" + (raw & 0xFFFF != 0 ? "-crop" : "")
    }

    func movieSweep() async {
        let modes: [UInt64] = [0x0F00_0870_0018_0000, 0x0780_0438_001E_0000, 0x0780_0438_003C_0000, 0x0780_0438_0078_0000]
        await sweep("movie", property: PTPPropertyCode(0xD0A0), values: modes.map { .unsigned($0) },
                    label: Self.movieModeLabel, settle: 2.5)
    }

    func compressionSweep() async {
        await sweep("compression", property: .nikonLiveViewImageCompression, values: (0...5).map { .unsigned(UInt64($0)) },
                    label: { "q\($0)" })
    }

    @ObservationIgnored private var originalMovieMode: PTPValue?
    @ObservationIgnored private var latencyRuns = 0
    @ObservationIgnored private var probes: [(t: Double, luma: Double, redBlue: Double)] = []
    @ObservationIgnored private let latestFrame = LatestFrame()

    private func probeAverage(seconds: Double = 0.8) async -> (luma: Double, redBlue: Double) {
        try? await Task.sleep(for: .seconds(seconds))
        let recent = probes.filter { $0.t > hostTime() - seconds }
        guard !recent.isEmpty else { return (0, 0) }
        return (median(recent.map(\.luma)), median(recent.map(\.redBlue)))
    }

    /// Does the live-view image follow exposure and white-balance settings?
    func exposurePreviewTest() async {
        guard let session else { return }
        if !session.isLiveViewRunning { startLiveView() }
        _ = await waitForFrames()
        let t = session.transport
        let movie = (try? await t.propertyValue(.nikonLiveViewSelector, type: .uint8))?.int == 1
        if let d = try? await t.propertyDescriptor(.nikonLiveViewExposurePreview) {
            log("LiveViewExposurePreview: \(d.current) writable \(d.isWritable) form \(d.form)")
        }
        let isoCode: PTPPropertyCode = movie ? .nikonMovieISO : .exposureIndex
        let wbCode: PTPPropertyCode = movie ? .nikonMovieWhiteBalance : .whiteBalance
        var lines: [String] = ["Live view: \(movie ? "movie" : "photo")"]

        if let iso = try? await t.propertyDescriptor(isoCode), let values = iso.allowedValues, let cur = iso.current.int,
           let lower = values.compactMap(\.int).filter({ $0 <= cur / 4 }).max() {
            let before = await probeAverage()
            _ = try? await t.setPropertyValue(isoCode, .unsigned(UInt64(lower)), type: iso.dataType)
            try? await Task.sleep(for: .seconds(1))
            let after = await probeAverage()
            _ = try? await t.setPropertyValue(isoCode, iso.current, type: iso.dataType)
            lines.append(String(format: "ISO %d → %d (−2 EV): luma %.3f → %.3f", cur, lower, before.luma, after.luma))
        }
        if let wb = try? await t.propertyDescriptor(wbCode), wb.allowedValues?.contains(.unsigned(6)) == true {
            let before = await probeAverage()
            _ = try? await t.setPropertyValue(wbCode, .unsigned(6), type: wb.dataType)
            try? await Task.sleep(for: .seconds(1))
            let after = await probeAverage()
            _ = try? await t.setPropertyValue(wbCode, wb.current, type: wb.dataType)
            lines.append(String(format: "WB %@ → 6 (incandescent): red/blue %.2f → %.2f", wb.current.description, before.redBlue, after.redBlue))
        }
        for line in lines { log("Exposure preview: " + line) }
        summary.append("- Exposure preview: " + lines.joined(separator: "; "))
    }

    /// What does Nikon GetLiveViewCompressedSize (0x9423) return, how fast, and does it track new frames?
    func compressedSizeProbe() async {
        guard let session else { return }
        if !session.isLiveViewRunning { startLiveView() }
        _ = await waitForFrames()
        await session.stopPolling()
        let t = session.transport
        if let first = try? await t.transact(PTPOperationCode(0x9423), params: [], dataOut: nil) {
            log("0x9423 → \(first.response.code), params \(first.response.params), data \(first.data.count) bytes \(first.data.prefix(16).map { String(format: "%02x", $0) }.joined()), RTT \(String(format: "%.2f", first.roundTrip * 1000)) ms")
        }
        // 1) How often does the value change, and how cheap is the call?
        var rtts: [Double] = [], changes = 0, last: Data?
        let end = hostTime() + 3
        while hostTime() < end {
            guard let r = try? await t.transact(PTPOperationCode(0x9423), params: [], dataOut: nil) else { break }
            rtts.append(r.roundTrip)
            let value = r.data + Data(r.response.params.flatMap { withUnsafeBytes(of: $0) { Array($0) } })
            if let last, value != last { changes += 1 }
            last = value
        }
        log(String(format: "0x9423 polled %d times in 3 s: RTT median %.2f ms, value changed %.1f /s", rtts.count, median(rtts) * 1000, Double(changes) / 3))
        // 2) Poll the size until it changes, then fetch the image: are fetched frames always new?
        var fetched = 0, repeats = 0, lastHash = 0, intervals: [Double] = [], lastNew = 0.0, lastSize: Data?
        let end2 = hostTime() + 5
        while hostTime() < end2 {
            guard let r = try? await t.transact(PTPOperationCode(0x9423), params: [], dataOut: nil) else { break }
            let value = r.data + Data(r.response.params.flatMap { withUnsafeBytes(of: $0) { Array($0) } })
            defer { lastSize = value }
            guard let lastSize, value != lastSize else { continue }
            guard let img = try? await t.transact(.nikonGetLiveViewImage, params: [], dataOut: nil),
                  let frame = NikonLiveViewFrame(payload: img.data) else { continue }
            var hasher = Hasher()
            frame.jpeg.withUnsafeBytes { hasher.combine(bytes: $0) }
            let h = hasher.finalize()
            fetched += 1
            if h == lastHash { repeats += 1 } else {
                if lastNew > 0 { intervals.append(img.completedAt - lastNew) }
                lastNew = img.completedAt
            }
            lastHash = h
        }
        let sortedIntervals = intervals.sorted()
        log(String(format: "Size-gated fetch, 5 s: %d fetched, %d repeats, %.1f fps new, interval p50 %.1f / p95 %.1f ms",
                   fetched, repeats, Double(fetched - repeats) / 5, percentile(sortedIntervals, 0.5) * 1000, percentile(sortedIntervals, 0.95) * 1000))
        session.startLiveView()
    }

    /// Unique fps per second, to see how fast live view settles.
    func timeline(seconds: Int) async {
        guard let session else { return }
        var values: [String] = []
        for _ in 0..<seconds {
            session.stats.reset()
            try? await Task.sleep(for: .seconds(1))
            values.append(String(format: "%.0f", Double(session.stats.snapshot().uniqueFrames)))
        }
        let line = "Timeline \(latencyContext)fps/s: " + values.joined(separator: " ")
        log(line)
        summary.append("- " + line)
    }

    /// For each live-view AF-area mode: can ChangeAfArea move the AF frame?
    func afAreaSweep() async {
        guard let session else { return }
        if !session.isLiveViewRunning { startLiveView() }
        _ = await waitForFrames()
        let t = session.transport
        guard let desc = try? await t.propertyDescriptor(.nikonLiveViewAFArea), let values = desc.allowedValues,
              let info = latestFrame.get()?.frame.info else { return log("AF area sweep: unavailable") }
        var lines: [String] = []
        for value in values {
            let set = try? await t.transact(.setDevicePropValue, params: [UInt32(PTPPropertyCode.nikonLiveViewAFArea.rawValue)],
                                            dataOut: try? PTPWriter.encode(value, as: desc.dataType))
            try? await Task.sleep(for: .milliseconds(600))
            let x = UInt32(info.sensorWidth / 4), y = UInt32(info.sensorHeight / 3)
            let move = try? await t.transact(.nikonChangeAfArea, params: [x, y], dataOut: nil)
            try? await Task.sleep(for: .milliseconds(600))
            let after = latestFrame.get()?.frame.info
            lines.append("AFArea \(value) [set \(set?.response.code.name ?? "?")]: move → \(move?.response.code.name ?? "?"), AF frame \(after.map { "\($0.afWidth)x\($0.afHeight) @ (\($0.afCenterX),\($0.afCenterY))" } ?? "?")")
        }
        _ = try? await t.setPropertyValue(.nikonLiveViewAFArea, desc.current, type: desc.dataType)
        _ = try? await t.transact(.nikonChangeAfArea, params: [UInt32(info.sensorWidth / 2), UInt32(info.sensorHeight / 2)], dataOut: nil)
        for line in lines { log("AF sweep: " + line) }
        summary.append("- AF sweep: " + lines.joined(separator: "; "))
    }

    /// Click-to-focus feasibility: move the AF area, check the header follows, run AF, nudge manual focus.
    func focusTest() async {
        guard let session else { return }
        if !session.isLiveViewRunning { startLiveView() }
        _ = await waitForFrames()
        let t = session.transport
        guard let info = latestFrame.get()?.frame.info else { return log("Focus: no header info") }
        var lines: [String] = []
        for code in [PTPPropertyCode.nikonLiveViewAFArea, .nikonLiveViewAFFocus, .nikonAutofocusMode, PTPPropertyCode(0xD1F8), PTPPropertyCode(0xD1FA)] {
            if let v = try? await t.propertyDescriptor(code) { lines.append("\(code.hex)=\(v.current)\(v.isWritable ? "" : " (ro)")") }
        }
        let target = (x: UInt32(info.sensorWidth / 4), y: UInt32(info.sensorHeight / 2))
        let move = try? await t.transact(.nikonChangeAfArea, params: [target.x, target.y], dataOut: nil)
        try? await Task.sleep(for: .milliseconds(500))
        let moved = latestFrame.get()?.frame.info
        lines.append("ChangeAfArea(\(target.x),\(target.y)) → \(move?.response.code.description ?? "error"); header AF center (\(info.afCenterX),\(info.afCenterY)) → (\(moved?.afCenterX ?? -1),\(moved?.afCenterY ?? -1))")

        let started = hostTime()
        let af = try? await t.transact(.nikonAfDrive, params: [], dataOut: nil)
        var ready = "n/a"
        if af?.response.code.isOK == true {
            do { try await t.nikonWaitUntilReady(timeout: 5); ready = "OK" } catch { ready = "\(error)" }
        }
        lines.append(String(format: "AfDrive → %@, DeviceReady %@ after %.0f ms", af?.response.code.description ?? "error", ready, (hostTime() - started) * 1000))

        for (direction, label) in [(UInt32(1), "near"), (UInt32(2), "far")] {
            let mf = try? await t.transact(.nikonMfDrive, params: [direction, 200], dataOut: nil)
            if mf?.response.code.isOK == true { try? await t.nikonWaitUntilReady(timeout: 3) }
            lines.append("MfDrive(\(label), 200) → \(mf?.response.code.description ?? "error")")
        }
        _ = try? await t.transact(.nikonChangeAfArea, params: [UInt32(info.afCenterX), UInt32(info.afCenterY)], dataOut: nil)
        for line in lines { log("Focus: " + line) }
        summary.append("- Focus: " + lines.joined(separator: "; "))
    }
    @ObservationIgnored private var latencyContext = ""

    /// `set=<code hex>:<type>:<value>`, e.g. `set=D0A0:u64:0x07800438003C0000` or `set=D1AC:u8:2`.
    func setStep(_ spec: String, settle: Double = 2.5) async {
        guard let session else { return }
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count == 3, let code = UInt16(parts[0], radix: 16) else { return log("Bad set step \(spec)") }
        let types: [String: PTPDataType] = ["u8": .uint8, "u16": .uint16, "u32": .uint32, "u64": .uint64, "i16": .int16]
        guard let type = types[parts[1]] else { return log("Bad type in \(spec)") }
        let raw = parts[2].hasPrefix("0x") ? UInt64(parts[2].dropFirst(2), radix: 16) : UInt64(parts[2])
        guard let raw else { return log("Bad value in \(spec)") }
        let property = PTPPropertyCode(code)
        let value = PTPValue.unsigned(raw)
        do {
            try await session.transport.setPropertyValue(property, value, type: type)
            latencyContext = "[\(property.hex)=\(code == 0xD0A0 ? Self.movieModeLabel(value) : value.description)] "
            log("Set \(property) = \(code == 0xD0A0 ? Self.movieModeLabel(value) : value.description)")
        } catch {
            log("Set \(property) failed: \(error)")
        }
        if settle > 0 {
            try? await Task.sleep(for: .seconds(settle))
            session.stats.reset()
        }
    }
    @ObservationIgnored private var goIndex = 0

    /// Best measured live-view configuration: 1080p30 movie mode (30 fps LV) at XGA size.
    func prepareBest() async {
        guard let session else { return }
        let movie = PTPPropertyCode(0xD0A0)
        if originalMovieMode == nil { originalMovieMode = try? await session.transport.propertyValue(movie, type: .uint64) }
        do {
            try await session.transport.setPropertyValue(movie, .unsigned(0x0780_0438_001E_0000), type: .uint64)
            try await session.transport.setPropertyValue(.nikonLiveViewImageSize, .unsigned(3), type: .uint8)
            log("Prepared: movie 1920x1080p30, live view XGA (original movie mode \(originalMovieMode.map(Self.movieModeLabel) ?? "?"))")
        } catch {
            log("Prepare failed: \(error)")
        }
        try? await Task.sleep(for: .seconds(2))
    }

    func restoreSettings() async {
        guard let session, let originalMovieMode else { return }
        do {
            try await session.transport.setPropertyValue(PTPPropertyCode(0xD0A0), originalMovieMode, type: .uint64)
            log("Restored movie mode \(Self.movieModeLabel(originalMovieMode))")
            self.originalMovieMode = nil
        } catch {
            log("Restore failed: \(error)")
        }
    }

    /// Pauses the auto run until `<out>/go<n>` exists (lets the operator re-aim the camera).
    func waitForGo() async {
        goIndex += 1
        let marker = outDir.appending(path: "go\(goIndex)")
        activity = "Waiting for go\(goIndex)…"
        log("Waiting for \(marker.lastPathComponent)")
        while !FileManager.default.fileExists(atPath: marker.path) { try? await Task.sleep(for: .milliseconds(250)) }
        activity = nil
        if session?.isLiveViewRunning == true { session?.stats.reset() }
    }

    /// One GetLiveViewImageEx (0x9428) call, compared with GetLiveViewImage.
    func exProbe() async {
        guard let session else { return }
        if !session.isLiveViewRunning { startLiveView() }
        _ = await waitForFrames()
        do {
            let t = try await session.transport.transact(.nikonGetLiveViewImageEx, params: [], dataOut: nil)
            let frame = NikonLiveViewFrame(payload: t.data)
            let dims = frame?.jpegDimensions
            let line = "GetLiveViewImageEx: \(t.response.code), \(t.data.count) bytes, JPEG at \(frame?.jpegOffset ?? -1), \(dims.map { "\($0.width)x\($0.height)" } ?? "no JPEG"), RTT \(String(format: "%.1f", t.roundTrip * 1000)) ms"
            log(line)
            summary.append("- " + line)
            try? t.data.write(to: outDir.appending(path: "samples/ex_1.bin"))
        } catch {
            log("GetLiveViewImageEx failed: \(error)")
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
        latencyRuns += 1
        ReportWriter.write(result, to: outDir.appending(path: "latency-\(latencyRuns).json"))
        let line = latencyContext + String(format: "Latency (glass-to-host, %d trials, %d timeouts): median %.0f ms, min %.0f, p90 %.0f, max %.0f; +decode median %.0f ms",
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
            case "movie": await movieSweep()
            case "compression": await compressionSweep()
            case "ex": await exProbe()
            case "prepare": await prepareBest()
            case "restore": await restoreSettings()
            case "target":
                latencyWindowRequested = true
                try? await Task.sleep(for: .milliseconds(800))
                _ = await latencyTarget.show(white: true)
            case "waitgo": await waitForGo()
            case "expsim": await exposurePreviewTest()
            case "focus": await focusTest()
            case "afsweep": await afAreaSweep()
            case "csize": await compressedSizeProbe()
            case let step where step.hasPrefix("set="): await setStep(String(step.dropFirst(4)))
            case let step where step.hasPrefix("setq="): await setStep(String(step.dropFirst(5)), settle: 0)
            case let step where step.hasPrefix("timeline="):
                await timeline(seconds: Int(step.dropFirst(9)) ?? 20)
            case "lvoff":
                await session?.stopLiveView()
                liveViewRunning = false
            case "lvon":
                session?.stats.reset()
                session?.startLiveView()
            case let step where step.hasPrefix("sleep="):
                try? await Task.sleep(for: .milliseconds(Int(step.dropFirst(6)) ?? 0))
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

nonisolated final class LatestFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: LiveFrame?
    func set(_ f: LiveFrame) { lock.withLock { frame = f } }
    func get() -> LiveFrame? { lock.withLock { frame } }
}

nonisolated private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
