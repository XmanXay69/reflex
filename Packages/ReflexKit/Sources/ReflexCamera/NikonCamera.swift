import Foundation
import ReflexPTP

/// A connected Nikon body: configures live view, runs the live-view loop, tracks battery and live-view mode,
/// and puts the settings it changed back when the session ends.
///
/// All camera traffic goes through one loop task, so live-view fetches, event polling and (from Milestone 3)
/// control commands never race each other.
public final class NikonCamera: @unchecked Sendable {
    public let connection: CameraConnection
    public private(set) var identity: CameraIdentity?

    private var transport: ImageCaptureTransport { connection.transport }

    private let lock = NSLock()
    private var status = CameraStatus()
    private var wantsLiveView = true
    private var quality: LiveViewQuality
    private var pacer: FramePacer
    private var loopTask: Task<Void, Never>?
    private var frameHandler: (@Sendable (LiveViewFrame) -> Void)?
    private var statusHandler: (@Sendable (CameraStatus) -> Void)?
    private var liveStats = LiveViewCounters()
    /// Original values of settings Reflex changed, restored by `shutdown()`.
    private var originals: [PTPPropertyCode: (PTPValue, PTPDataType)] = [:]
    private var reconfigureNeeded = false

    public init(connection: CameraConnection, quality: LiveViewQuality, pacing: Bool = true) {
        self.connection = connection
        self.quality = quality
        self.pacer = FramePacer(isEnabled: pacing)
    }

    public func onFrame(_ handler: @escaping @Sendable (LiveViewFrame) -> Void) { lock.withLock { frameHandler = handler } }
    public func onStatus(_ handler: @escaping @Sendable (CameraStatus) -> Void) { lock.withLock { statusHandler = handler } }

    public var currentStatus: CameraStatus { lock.withLock { status } }

    /// Transport-level counters since the last call (request rate, repeats, round trip).
    public func takeCounters() -> LiveViewCounters {
        lock.withLock {
            let c = liveStats
            liveStats = LiveViewCounters()
            return c
        }
    }

    // MARK: Lifecycle

    /// Reads the camera's identity and checks it can do USB live view. The first command after a session opens
    /// can take several seconds while macOS catalogs the memory card.
    public func prepare() async throws -> CameraIdentity {
        let info = try await transport.deviceInfo()
        guard info.isNikon, info.supports(.nikonStartLiveView), info.supports(.nikonGetLiveViewImage) else {
            throw CameraError.notSupported(info.model)
        }
        let identity = CameraIdentity(manufacturer: info.manufacturer, model: info.model, firmware: info.deviceVersion,
                                      usbLinkSpeed: USBLinkSpeed.lookup(locationID: connection.usbLocationID))
        self.identity = identity
        await refreshBattery()
        await refreshMode()
        return identity
    }

    /// Starts the camera loop (live view on by default).
    public func start() {
        lock.withLock {
            guard loopTask == nil else { return }
            loopTask = Task.detached(priority: .high) { [self] in await runLoop() }
        }
    }

    public func setLiveViewEnabled(_ enabled: Bool) { lock.withLock { wantsLiveView = enabled } }

    public func setQuality(_ quality: LiveViewQuality) {
        lock.withLock {
            self.quality = quality
            reconfigureNeeded = true
        }
    }

    /// Stops live view and restores every setting Reflex changed. Safe to call more than once.
    public func shutdown() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let t = loopTask
            loopTask = nil
            return t
        }
        task?.cancel()
        await task?.value
        if (try? await transport.propertyValue(.nikonLiveViewStatus, type: .uint8))?.int == 1 {
            _ = try? await transport.transact(.nikonEndLiveView, params: [], dataOut: nil)
        }
        let restore = lock.withLock { () -> [PTPPropertyCode: (PTPValue, PTPDataType)] in
            let r = originals
            originals.removeAll()
            return r
        }
        for (code, original) in restore {
            _ = try? await transport.setPropertyValue(code, original.0, type: original.1)
        }
        updateStatus { $0.liveViewRunning = false }
    }

    // MARK: Loop

    private func runLoop() async {
        var inLiveView = false
        var lastEventPoll = 0.0
        var lastBatteryRead = hostTime()
        var lastHash: Int?
        var lastWasRepeat = false
        var skipNext = true
        var sequence = 0

        while !Task.isCancelled {
            let now = hostTime()
            if now - lastEventPoll > 0.25 {
                lastEventPoll = now
                await pollEvents()
            }
            if now - lastBatteryRead > 30 {
                lastBatteryRead = now
                await refreshBattery()
            }
            let (wants, reconfigure) = lock.withLock { () -> (Bool, Bool) in
                let r = reconfigureNeeded
                reconfigureNeeded = false
                return (wantsLiveView, r)
            }
            if reconfigure, inLiveView { await configureLiveView() }

            if wants, !inLiveView {
                do {
                    try await enterLiveView()
                    inLiveView = true
                    skipNext = true
                    lastHash = nil
                    lock.withLock { pacer.reset() }
                    updateStatus { $0.liveViewRunning = true; $0.problem = nil }
                } catch PTPError.disconnected {
                    return
                } catch {
                    updateStatus { $0.liveViewRunning = false; $0.problem = "\(error)" }
                    try? await Task.sleep(for: .seconds(2))
                }
                continue
            }
            if !wants, inLiveView {
                _ = try? await transport.transact(.nikonEndLiveView, params: [], dataOut: nil)
                inLiveView = false
                updateStatus { $0.liveViewRunning = false }
                continue
            }
            guard inLiveView else {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }

            let wait = lock.withLock { pacer.delay(now: hostTime(), lastWasRepeat: lastWasRepeat) }
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

            do {
                let t = try await transport.transact(.nikonGetLiveViewImage, params: [], dataOut: nil)
                let code = t.response.code
                lock.withLock { liveStats.record(t, ok: code.isOK) }
                switch code {
                case .ok:
                    guard let frame = NikonLiveViewFrame(payload: t.data) else { continue }
                    if skipNext { skipNext = false; continue } // the first frame after StartLiveView can be stale
                    let hash = Self.fingerprint(frame.jpeg)
                    if hash == lastHash {
                        lastWasRepeat = true
                        lock.withLock { liveStats.repeats += 1 }
                        continue
                    }
                    lastHash = hash
                    lastWasRepeat = false
                    sequence += 1
                    let handler = lock.withLock { () -> (@Sendable (LiveViewFrame) -> Void)? in
                        pacer.newFrame(requestedAt: t.sentAt)
                        return frameHandler
                    }
                    handler?(LiveViewFrame(frame: frame, info: frame.info, requestedAt: t.sentAt,
                                           arrivedAt: t.completedAt, sequence: sequence))
                case .deviceBusy:
                    lastWasRepeat = true
                case .nikonNotLiveView:
                    inLiveView = false
                default:
                    try? await Task.sleep(for: .milliseconds(20))
                }
            } catch PTPError.disconnected {
                return
            } catch {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func enterLiveView() async throws {
        await refreshMode()
        await configureLiveView()
        if (try? await transport.propertyValue(.nikonLiveViewStatus, type: .uint8))?.int == 1 { return }
        if let condition = try? await transport.propertyValue(.nikonLiveViewProhibitCondition, type: .uint32),
           let bits = condition.int, bits != 0 {
            throw CameraError.liveViewRefused(NikonLiveView.prohibitReasons(UInt32(bits)))
        }
        let t = try await transport.transact(.nikonStartLiveView, params: [], dataOut: nil)
        guard t.response.code.isOK || t.response.code == .deviceBusy else {
            throw PTPError.response(t.response.code, operation: .nikonStartLiveView)
        }
        try await transport.nikonWaitUntilReady(timeout: 5)
    }

    /// XGA frames (the camera resets this every session), exposure preview in photo live view so exposure
    /// settings show in the image, and the chosen JPEG quality.
    private func configureLiveView() async {
        let (quality, mode) = lock.withLock { (self.quality, status.liveViewMode) }
        await set(.nikonLiveViewImageSize, .unsigned(3), .uint8, remember: false)
        if mode == .photo { await set(.nikonLiveViewExposurePreview, .unsigned(1), .uint8) }
        await set(.nikonLiveViewImageCompression, .unsigned(UInt64(quality.cameraLevel)), .uint8)
    }

    /// Sets a property if it differs, remembering the first original value for `shutdown()`.
    private func set(_ code: PTPPropertyCode, _ value: PTPValue, _ type: PTPDataType, remember: Bool = true) async {
        guard let current = try? await transport.propertyValue(code, type: type), current != value else { return }
        do {
            try await transport.setPropertyValue(code, value, type: type)
            if remember { lock.withLock { if originals[code] == nil { originals[code] = (current, type) } } }
        } catch {
            // Not every body/mode accepts every setting; live view still works without it.
        }
    }

    private func pollEvents() async {
        guard let events = try? await transport.nikonEvents() else { return }
        let changed = Set(events.filter { $0.code == .devicePropChanged }.compactMap { $0.params.first.map { UInt16(truncatingIfNeeded: $0) } })
        if changed.contains(PTPPropertyCode.batteryLevel.rawValue) { await refreshBattery() }
        if changed.contains(PTPPropertyCode.nikonLiveViewSelector.rawValue) {
            let before = lock.withLock { status.liveViewMode }
            await refreshMode()
            if lock.withLock({ status.liveViewMode }) != before { lock.withLock { reconfigureNeeded = true } }
        }
    }

    private func refreshBattery() async {
        guard let value = try? await transport.propertyValue(.batteryLevel, type: .uint8) else { return }
        updateStatus { $0.batteryPercent = value.int }
    }

    private func refreshMode() async {
        guard let value = try? await transport.propertyValue(.nikonLiveViewSelector, type: .uint8) else { return }
        updateStatus { $0.liveViewMode = value.int == 1 ? .movie : .photo }
    }

    private func updateStatus(_ change: (inout CameraStatus) -> Void) {
        let (snapshot, handler, changed) = lock.withLock { () -> (CameraStatus, (@Sendable (CameraStatus) -> Void)?, Bool) in
            let before = status
            change(&status)
            return (status, statusHandler, status != before)
        }
        if changed { handler?(snapshot) }
    }

    private static func fingerprint(_ data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }
}

/// Transport counters for the status bar and diagnostics.
public struct LiveViewCounters: Sendable {
    public var requests = 0
    public var repeats = 0
    public var bytes = 0
    public var roundTripTotal = 0.0
    public var since = hostTime()

    mutating func record(_ t: PTPTransaction, ok: Bool) {
        requests += 1
        if ok { bytes += t.data.count }
        roundTripTotal += t.roundTrip
    }

    public var seconds: Double { max(hostTime() - since, 0.001) }
    public var requestRate: Double { Double(requests) / seconds }
    public var meanRoundTrip: Double { requests == 0 ? 0 : roundTripTotal / Double(requests) }
    public var megabytesPerSecond: Double { Double(bytes) / seconds / 1_048_576 }
}
