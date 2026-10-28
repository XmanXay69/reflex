import Foundation
import ReflexPTP

/// A live-view frame as it came off the wire.
nonisolated struct LiveFrame: Sendable {
    var frame: NikonLiveViewFrame
    var requestedAt: Double
    var arrivedAt: Double
    var sequence: Int
}

nonisolated enum SpikeError: Error, CustomStringConvertible {
    case liveViewProhibited(UInt32, [String])
    case notNikon(String)

    var description: String {
        switch self {
        case let .liveViewProhibited(bits, reasons):
            String(format: "Live view refused (condition 0x%08X): ", bits) + (reasons.isEmpty ? "unknown reason" : reasons.joined(separator: ", "))
        case let .notNikon(model): "\(model) is not a Nikon; the spike only speaks Nikon live view"
        }
    }
}

/// Nikon live view and property access over a PTP transport. Owns the live-view polling loop.
nonisolated final class CameraSession: @unchecked Sendable {
    let connection: CameraConnection
    let stats = LiveStats()
    private let log: @Sendable (String) -> Void

    private let lock = NSLock()
    private var liveViewTask: Task<Void, Never>?
    private var frameHandler: (@Sendable (LiveFrame) -> Void)?
    private var sampleSink: (@Sendable (LiveFrame) -> Void)?
    private var eventHandler: (@Sendable ([PTPEvent]) -> Void)?

    var transport: ImageCaptureTransport { connection.transport }

    init(connection: CameraConnection, log: @escaping @Sendable (String) -> Void) {
        self.connection = connection
        self.log = log
    }

    func onFrame(_ handler: @escaping @Sendable (LiveFrame) -> Void) { lock.withLock { frameHandler = handler } }
    func onEvents(_ handler: @escaping @Sendable ([PTPEvent]) -> Void) { lock.withLock { eventHandler = handler } }
    /// Receives every unique frame until cleared (used to save samples).
    func setSampleSink(_ sink: (@Sendable (LiveFrame) -> Void)?) { lock.withLock { sampleSink = sink } }

    var isLiveViewRunning: Bool { lock.withLock { liveViewTask != nil } }

    // MARK: Probe

    struct ProbeResult: Sendable {
        var info: PTPDeviceInfo
        var vendorProperties: [PTPPropertyCode]
        var descriptors: [PTPPropertyCode: PTPPropertyDescriptor]
        var failures: [PTPPropertyCode: String]
        var seconds: Double
    }

    func probe() async throws -> ProbeResult {
        let started = hostTime()
        let info = try await transport.deviceInfo()
        var vendor: [PTPPropertyCode] = []
        if info.isNikon, info.supports(.nikonGetVendorPropCodes) {
            vendor = (try? await transport.nikonVendorPropertyCodes()) ?? []
        }
        var descriptors: [PTPPropertyCode: PTPPropertyDescriptor] = [:]
        var failures: [PTPPropertyCode: String] = [:]
        for code in Set(info.properties + vendor).sorted(by: { $0.rawValue < $1.rawValue }) {
            do { descriptors[code] = try await transport.propertyDescriptor(code) }
            catch { failures[code] = "\(error)" }
        }
        return ProbeResult(info: info, vendorProperties: vendor, descriptors: descriptors,
                           failures: failures, seconds: hostTime() - started)
    }

    // MARK: Live view

    func startLiveView() {
        lock.lock()
        guard liveViewTask == nil else { lock.unlock(); return }
        liveViewTask = Task.detached(priority: .high) { [self] in
            do {
                try await enterLiveView()
                await pollLoop()
            } catch {
                log("Live view failed to start: \(error)")
            }
            lock.withLock { liveViewTask = nil }
        }
        lock.unlock()
    }

    /// Stops the polling loop but leaves the camera in live view.
    func stopPolling() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let t = liveViewTask
            liveViewTask = nil
            return t
        }
        task?.cancel()
        await task?.value
    }

    func stopLiveView() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let t = liveViewTask
            liveViewTask = nil
            return t
        }
        task?.cancel()
        await task?.value
        do {
            try await transport.run(.nikonEndLiveView)
            log("Live view stopped")
        } catch {
            log("EndLiveView: \(error)")
        }
    }

    private func enterLiveView() async throws {
        if let status = try? await transport.propertyValue(.nikonLiveViewStatus, type: .uint8), status.int == 1 {
            log("Camera already in live view")
            return
        }
        if let condition = try? await transport.propertyValue(.nikonLiveViewProhibitCondition, type: .uint32),
           let bits = condition.int, bits != 0 {
            throw SpikeError.liveViewProhibited(UInt32(bits), Self.prohibitReasons(UInt32(bits)))
        }
        let started = hostTime()
        let t = try await transport.transact(.nikonStartLiveView, params: [], dataOut: nil)
        guard t.response.code.isOK || t.response.code == .deviceBusy else {
            throw PTPError.response(t.response.code, operation: .nikonStartLiveView)
        }
        try await transport.nikonWaitUntilReady(timeout: 5)
        log(String(format: "Live view started in %.0f ms", (hostTime() - started) * 1000))
    }

    private func pollLoop() async {
        var lastHash: Int?
        var sequence = 0
        var skipFirst = true
        var lastEventPoll = 0.0
        while !Task.isCancelled {
            let now = hostTime()
            if now - lastEventPoll > 0.25 {
                lastEventPoll = now
                if let events = try? await transport.nikonEvents(), !events.isEmpty {
                    lock.withLock { eventHandler }?(events)
                }
            }
            do {
                let t = try await transport.transact(.nikonGetLiveViewImage, params: [], dataOut: nil)
                let code = t.response.code
                stats.response(ok: code.isOK, busy: code == .deviceBusy, rtt: t.roundTrip, bytes: t.data.count)
                switch code {
                case .ok:
                    guard let frame = NikonLiveViewFrame(payload: t.data) else { stats.badFrame(); continue }
                    if skipFirst { skipFirst = false; continue } // first frame after StartLiveView can be stale
                    let hash = Self.fingerprint(frame.jpeg)
                    if hash == lastHash { stats.duplicate(); continue }
                    lastHash = hash
                    sequence += 1
                    let dims = frame.jpegDimensions
                    stats.unique(at: t.completedAt, width: dims?.width ?? 0, height: dims?.height ?? 0, headerBytes: frame.jpegOffset)
                    let live = LiveFrame(frame: frame, requestedAt: t.sentAt, arrivedAt: t.completedAt, sequence: sequence)
                    let (handler, sink) = lock.withLock { (frameHandler, sampleSink) }
                    handler?(live)
                    sink?(live)
                case .deviceBusy:
                    try? await Task.sleep(nanoseconds: 2_000_000)
                case .nikonNotLiveView:
                    log("Camera left live view; re-entering")
                    try await enterLiveView()
                    skipFirst = true
                default:
                    log("GetLiveViewImage: \(code)")
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            } catch PTPError.disconnected {
                log("Camera disconnected during live view")
                return
            } catch {
                log("Live view error: \(error)")
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private static func fingerprint(_ data: Data) -> Int {
        var hasher = Hasher()
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }

    /// Bit meanings for Nikon LiveViewProhibitCondition (0xD1A4), per libgphoto2's Nikon driver notes.
    static func prohibitReasons(_ bits: UInt32) -> [String] {
        let table: [(Int, String)] = [
            (31, "mode dial is not P/A/S/M"), (24, "lens is retracting"), (22, "mirror-up in progress"),
            (21, "bulb warning"), (20, "card unformatted"), (19, "card error"), (18, "card protected"),
            (17, "temperature too high"), (15, "shooting in progress"), (14, "no card / card protected"),
            (12, "unretrieved image in camera buffer"), (9, "TTL error"), (8, "battery exhausted"),
            (5, "minimum aperture warning"), (4, "shutter button fully pressed"), (2, "sequence error"),
        ]
        return table.filter { bits & (1 << UInt32($0.0)) != 0 }.map(\.1)
    }
}
