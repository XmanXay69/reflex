import Foundation
import ReflexPTP

/// The exposure controls Reflex exposes. Each maps to a different camera property in photo and movie live view:
/// the D780 keeps separate settings for movies.
public enum ExposureControl: String, CaseIterable, Sendable, Identifiable {
    case mode, shutter, aperture, iso, autoISO, compensation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mode: "Mode"
        case .shutter: "Shutter"
        case .aperture: "Aperture"
        case .iso: "ISO"
        case .autoISO: "Auto ISO"
        case .compensation: "Exposure comp."
        }
    }

    /// Property code and data type for this control in the given live-view mode (verified on a D780).
    func property(for mode: LiveViewMode) -> (code: PTPPropertyCode, type: PTPDataType) {
        switch (self, mode) {
        case (.mode, _): (.exposureProgramMode, .uint16)
        case (.shutter, .photo): (.exposureTime, .uint32)
        case (.shutter, .movie): (.nikonMovieShutterSpeed, .uint32)
        case (.aperture, .photo): (.fNumber, .uint16)
        case (.aperture, .movie): (.nikonMovieFNumber, .uint16)
        case (.iso, .photo): (.exposureIndex, .uint16)
        case (.iso, .movie): (.nikonMovieISO, .uint32)
        case (.autoISO, .photo): (.nikonISOAuto, .uint8)
        case (.autoISO, .movie): (.nikonMovieISOAutoControl, .uint8)
        case (.compensation, .photo): (.exposureBiasCompensation, .int16)
        case (.compensation, .movie): (.nikonMovieExposureBiasCompensation, .int16)
        }
    }
}

/// What the camera currently allows for one control.
public struct ControlState: Sendable, Equatable, Identifiable {
    public var control: ExposureControl
    public var mode: LiveViewMode
    public var code: PTPPropertyCode
    public var type: PTPDataType
    public var value: PTPValue
    /// Values the camera accepts right now, in the camera's order.
    public var options: [PTPValue]
    public var isWritable: Bool

    public var id: ExposureControl { control }
    public var index: Int? { options.firstIndex(of: value) }
    public var label: String { label(for: value) }

    public func label(for value: PTPValue) -> String {
        ControlFormatter.label(control, mode: mode, value: value)
    }
}

enum ControlFormatter {
    static func label(_ control: ExposureControl, mode: LiveViewMode, value: PTPValue) -> String {
        guard let v = value.int else { return value.description }
        switch control {
        case .mode:
            return [1: "M", 2: "P", 3: "A", 4: "S", 0x8010: "Auto"][v] ?? String(format: "0x%04X", v)
        case .shutter:
            return mode == .photo ? photoShutter(v) : movieShutter(v)
        case .aperture:
            let f = Double(v) / 100
            return f < 10 ? String(format: "f/%.1f", f) : String(format: "f/%.0f", f)
        case .iso:
            return "\(v)"
        case .autoISO:
            return v == 0 ? "Off" : "On"
        case .compensation:
            if v == 0 { return "0 EV" }
            return String(format: "%+.1f EV", Double(v) / 1000)
        }
    }

    /// PTP ExposureTime (0x500D) is in units of 1/10 000 s.
    static func photoShutter(_ v: Int) -> String {
        switch v {
        case 0xFFFF_FFFF: return "Bulb"
        case 0xFFFF_FFFD: return "Time"
        case 0xFFFF_FFFC, 0xFFFF_FFFE: return "Flash"
        default: break
        }
        guard v > 0 else { return "\(v)" }
        if v >= 10_000 {
            let seconds = Double(v) / 10_000
            return seconds.rounded() == seconds ? String(format: "%.0f\"", seconds) : String(format: "%.1f\"", seconds)
        }
        return "1/\(Int((10_000 / Double(v)).rounded()))"
    }

    /// Nikon MovieShutterSpeed (0xD1A8): numerator in the high 16 bits, denominator in the low 16 bits.
    static func movieShutter(_ v: Int) -> String {
        let numerator = v >> 16, denominator = v & 0xFFFF
        guard numerator > 0, denominator > 0 else { return "\(v)" }
        if numerator == 1 { return "1/\(denominator)" }
        return String(format: "%.1f\"", Double(numerator) / Double(denominator))
    }
}

extension PTPPropertyCode {
    static let nikonMovieISOAutoControl = PTPPropertyCode(0xD0AD)
}
