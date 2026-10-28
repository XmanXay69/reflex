import Foundation
import ReflexPTP

/// Which live view the camera is in. On the D780 this follows the physical LV selector.
public enum LiveViewMode: String, Sendable, Equatable {
    case photo, movie

    public var label: String { self == .photo ? "Photo" : "Movie" }
}

/// JPEG quality of live-view frames (Nikon LiveViewImageCompression, 0xD1BC, levels 0–5).
public enum LiveViewQuality: String, CaseIterable, Sendable, Identifiable {
    case efficient, high, max

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .efficient: "Efficient"
        case .high: "High"
        case .max: "Max"
        }
    }
    /// Camera compression level. Measured on a D780 in photo live view: 1 ≈ 100 KB, 3 ≈ 220 KB, 5 ≈ 340 KB per frame.
    public var cameraLevel: UInt8 {
        switch self {
        case .efficient: 1
        case .high: 3
        case .max: 5
        }
    }
}

public struct CameraIdentity: Sendable, Equatable {
    public var manufacturer: String
    public var model: String
    public var firmware: String
    public var usbLinkSpeed: USBLinkSpeed?
}

/// What the camera reports while connected; delivered on every change.
public struct CameraStatus: Sendable, Equatable {
    public var batteryPercent: Int?
    public var liveViewMode: LiveViewMode?
    public var liveViewRunning = false
    /// A problem the user can fix (mode dial, card, temperature…), or nil.
    public var problem: String?

    public init() {}
}

/// One live-view frame straight off the wire.
public struct LiveViewFrame: Sendable {
    public var frame: NikonLiveViewFrame
    public var info: NikonLiveViewInfo?
    /// Host time the request was sent / the response arrived (seconds, `hostTime()` clock).
    public var requestedAt: Double
    public var arrivedAt: Double
    public var sequence: Int
}

public enum CameraError: Error, CustomStringConvertible, Equatable {
    case notSupported(String)
    case liveViewRefused([String])

    public var description: String {
        switch self {
        case let .notSupported(model): "\(model) doesn't support Nikon USB live view."
        case let .liveViewRefused(reasons):
            reasons.isEmpty ? "The camera refused live view." : "Live view unavailable: " + reasons.joined(separator: ", ") + "."
        }
    }
}

enum NikonLiveView {
    /// Bit meanings of LiveViewProhibitCondition (0xD1A4), per libgphoto2's Nikon driver notes,
    /// phrased as what the user should fix.
    static func prohibitReasons(_ bits: UInt32) -> [String] {
        let table: [(UInt32, String)] = [
            (31, "turn the mode dial to P, S, A or M"), (24, "the lens is retracting"), (22, "mirror-up is in progress"),
            (21, "the shutter is set to Bulb"), (20, "the memory card is unformatted"), (19, "memory card error"),
            (18, "the memory card is locked"), (17, "the camera is too hot"), (15, "the camera is busy shooting"),
            (14, "insert a memory card"), (12, "an image is waiting in the camera's buffer"), (9, "TTL error"),
            (8, "the battery is empty"), (5, "set the lens to its minimum aperture"),
            (4, "release the shutter button"), (2, "sequence error"),
        ]
        return table.filter { bits & (1 << $0.0) != 0 }.map(\.1)
    }
}
