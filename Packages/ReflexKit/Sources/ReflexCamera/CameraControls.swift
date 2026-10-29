import Foundation
import ReflexPTP

/// The camera controls Reflex exposes. Each maps to a different camera property in photo and movie live view:
/// the D780 keeps separate settings for movies. Every one listed here was verified to change the live-view image
/// (Active D-Lighting was tested and doesn't, so it isn't here).
public enum CameraControl: String, CaseIterable, Sendable, Identifiable {
    case mode, shutter, aperture, iso, autoISO, compensation
    case whiteBalance, colorTemperature, pictureControl

    public enum Group: Sendable { case exposure, color }

    public var id: String { rawValue }
    public var group: Group {
        switch self {
        case .whiteBalance, .colorTemperature, .pictureControl: .color
        default: .exposure
        }
    }

    public var title: String {
        switch self {
        case .mode: "Mode"
        case .shutter: "Shutter"
        case .aperture: "Aperture"
        case .iso: "ISO"
        case .autoISO: "Auto ISO"
        case .compensation: "Exposure comp."
        case .whiteBalance: "White balance"
        case .colorTemperature: "Color temperature"
        case .pictureControl: "Picture Control"
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
        case (.whiteBalance, .photo): (.whiteBalance, .uint16)
        case (.whiteBalance, .movie): (.nikonMovieWhiteBalance, .uint16)
        case (.colorTemperature, .photo): (.nikonWhiteBalanceColorTemperature, .uint16)
        case (.colorTemperature, .movie): (.nikonMovieWbColorTemp, .uint16)
        case (.pictureControl, .photo): (.nikonActivePicCtrlItem, .uint16)
        case (.pictureControl, .movie): (.nikonMovieActivePicCtrlItem, .uint16)
        }
    }

    /// Trims what the camera offers to what's useful in a panel: Kelvin in 100 K steps; Picture Controls whose
    /// names were verified on a D780 (the Creative and custom slots are left out until verified).
    func usableOptions(_ options: [PTPValue], current: PTPValue) -> [PTPValue] {
        switch self {
        case .colorTemperature:
            return options.filter { ($0.int ?? 0) % 100 == 0 || $0 == current }
        case .pictureControl:
            return options.filter { (1...8).contains($0.int ?? 0) || $0.int == 100 || $0 == current }
        default:
            return options
        }
    }

    /// White-balance value meaning "use the Kelvin setting".
    public static let colorTemperatureWhiteBalance = PTPValue.unsigned(0x8012)
}

/// What the camera currently allows for one control.
public struct ControlState: Sendable, Equatable, Identifiable {
    public var control: CameraControl
    public var mode: LiveViewMode
    public var code: PTPPropertyCode
    public var type: PTPDataType
    public var value: PTPValue
    /// Values the camera accepts right now, in the camera's order.
    public var options: [PTPValue]
    public var isWritable: Bool

    public var id: CameraControl { control }
    public var index: Int? { options.firstIndex(of: value) }
    public var label: String { label(for: value) }

    public func label(for value: PTPValue) -> String {
        ControlFormatter.label(control, mode: mode, value: value)
    }
}

enum ControlFormatter {
    static func label(_ control: CameraControl, mode: LiveViewMode, value: PTPValue) -> String {
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
        case .whiteBalance:
            // Standard PTP codes plus Nikon's vendor range; 0x8015 is "same as photo" in the movie menu.
            let names: [Int: String] = [2: "Auto", 4: "Sunny", 5: "Fluorescent", 6: "Incandescent", 7: "Flash",
                                        0x8010: "Cloudy", 0x8011: "Shade", 0x8012: "Kelvin", 0x8013: "Preset",
                                        0x8015: "Same as photo", 0x8016: "Natural light auto"]
            return names[v] ?? String(format: "0x%04X", v)
        case .colorTemperature:
            return "\(v) K"
        case .pictureControl:
            // Order verified on a D780 by measuring saturation (Vivid highest, Monochrome zero, Flat lowest contrast).
            let names: [Int: String] = [1: "Standard", 2: "Neutral", 3: "Vivid", 4: "Monochrome", 5: "Portrait",
                                        6: "Landscape", 7: "Flat", 8: "Auto", 100: "Same as photo"]
            return names[v] ?? (v >= 201 ? "Custom \(v - 200)" : v >= 101 ? "Creative \(v - 100)" : "\(v)")
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
        // The camera rounds to whole 1/10 000 s (1/160 s arrives as 62 → "1/161"), so snap to the nearest
        // standard 1/3-stop speed in log space.
        let seconds = Double(v) / 10_000
        let nominal = nominalShutterSpeeds.min { abs(log($0.seconds / seconds)) < abs(log($1.seconds / seconds)) }!
        // Allow for the camera's rounding to whole units, which is coarse at the fast end (1/8000 s is stored as 1).
        let tolerance = 0.12 + log(1 + 0.5 / Double(v))
        return abs(log(nominal.seconds / seconds)) < tolerance ? nominal.label : String(format: "%.4g s", seconds)
    }

    /// Standard 1/3-stop shutter speeds from 1/8000 s to 30 s.
    static let nominalShutterSpeeds: [(seconds: Double, label: String)] = {
        let fractions = [8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320, 250, 200,
                         160, 125, 100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4, 3]
        let longer: [Double] = [0.4, 0.5, 0.6, 0.8, 1, 1.3, 1.6, 2, 2.5, 3, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30]
        return fractions.map { (1 / Double($0), "1/\($0)") }
            + longer.map { ($0, $0 < 1 ? "\(String(format: "%g", $0))\"" : String(format: "%g\"", $0)) }
    }()

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
    static let nikonMovieWbColorTemp = PTPPropertyCode(0xD21A)
    static let nikonMovieActivePicCtrlItem = PTPPropertyCode(0xD237)
}
