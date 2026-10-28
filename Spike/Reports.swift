import Foundation
import ReflexPTP

struct ProbeReport: Codable {
    struct Property: Codable {
        var code: String
        var name: String?
        var type: String
        var writable: Bool
        var current: String
        var factoryDefault: String
        var form: String
        var values: [String]?
        var range: [String]?
    }

    var manufacturer: String
    var model: String
    var firmware: String
    var usbVendorProduct: String
    var vendorExtension: String
    var operations: [String]
    var events: [String]
    var vendorOnlyProperties: [String]
    var properties: [Property]
    var failures: [String: String]
    var probeSeconds: Double

    init(_ probe: CameraSession.ProbeResult, connection: CameraConnection) {
        let info = probe.info
        manufacturer = info.manufacturer
        model = info.model
        firmware = info.deviceVersion
        usbVendorProduct = String(format: "%04x:%04x", connection.usbVendorID, connection.usbProductID)
        vendorExtension = String(format: "0x%08X v%d \"%@\"", info.vendorExtensionID, info.vendorExtensionVersion,
                                 info.vendorExtensionDescription)
        operations = info.operations.map(\.description)
        events = info.events.map(\.description)
        vendorOnlyProperties = probe.vendorProperties.filter { !info.properties.contains($0) }.map(\.description)
        properties = probe.descriptors.keys.sorted { $0.rawValue < $1.rawValue }.map { code in
            let d = probe.descriptors[code]!
            var p = Property(code: code.hex, name: code.name, type: d.dataType.name ?? d.dataType.hex,
                             writable: d.isWritable, current: d.current.description,
                             factoryDefault: d.factoryDefault.description, form: "none")
            switch d.form {
            case .none: break
            case let .enumeration(values): p.form = "enum"; p.values = values.map(\.description)
            case let .range(lo, hi, step): p.form = "range"; p.range = [lo.description, hi.description, step.description]
            }
            return p
        }
        failures = Dictionary(uniqueKeysWithValues: probe.failures.map { ($0.key.description, $0.value) })
        probeSeconds = probe.seconds
    }
}

struct BenchmarkReport: Codable {
    struct Row: Codable {
        var liveViewImageSize: String
        var stats: LiveStats.Snapshot
    }
    var context: [String: String]
    var rows: [Row]
}

struct SettingTestReport: Codable {
    struct Row: Codable {
        var property: String
        var before: String
        var target: String
        var setRoundTripMs: Double?
        var readBack: String?
        var applied: Bool
        var restored: Bool
        var liveViewKeptRunning: Bool
        var eventsSeen: [String]
        var error: String?
    }
    var rows: [Row]
}

enum ReportWriter {
    static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url)
        } catch {
            print("report write failed: \(error)")
        }
    }
}
