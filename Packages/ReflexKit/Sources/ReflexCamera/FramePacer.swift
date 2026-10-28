import Foundation

/// Decides when to ask the camera for the next live-view frame.
///
/// `GetLiveViewImage` returns whatever frame is newest, and a repeat costs a full JPEG transfer (up to ~340 KB).
/// Polling flat out therefore wastes USB bandwidth and makes a fresh frame wait behind a useless transfer.
/// The pacer learns the camera's frame period and phase from the send times of requests that returned a *new*
/// frame, schedules the next request just before the next frame is due, and retries quickly when it was early.
public struct FramePacer: Sendable {
    public var isEnabled: Bool
    /// How long before the predicted frame time to ask (absorbs jitter in the camera's clock).
    public var lead: Double = 0.001
    /// Retry delay after a repeat frame.
    public var retry: Double = 0.0015

    private var period: Double = 1.0 / 30
    private var lastNewFrameRequest: Double?

    public init(isEnabled: Bool = true) { self.isEnabled = isEnabled }

    public var estimatedPeriod: Double { period }

    /// Call when a request sent at `requestedAt` returned a new frame.
    public mutating func newFrame(requestedAt: Double) {
        if let last = lastNewFrameRequest {
            let interval = requestedAt - last
            // Ignore gaps (stalls, missed frames); learn only from plausible single-frame intervals.
            if interval > 0.012, interval < 0.070 { period += (interval - period) * 0.1 }
        }
        lastNewFrameRequest = requestedAt
    }

    /// Seconds to wait before the next request.
    public func delay(now: Double, lastWasRepeat: Bool) -> Double {
        guard isEnabled else { return 0 }
        if lastWasRepeat { return retry }
        guard let last = lastNewFrameRequest else { return 0 }
        return max(0, last + period - lead - now)
    }

    public mutating func reset() { lastNewFrameRequest = nil }
}
