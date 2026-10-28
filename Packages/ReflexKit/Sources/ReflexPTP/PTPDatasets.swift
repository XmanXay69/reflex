import Foundation

/// GetDeviceInfo (0x1001) dataset.
public struct PTPDeviceInfo: Sendable, Equatable {
    public var standardVersion: UInt16
    public var vendorExtensionID: UInt32
    public var vendorExtensionVersion: UInt16
    public var vendorExtensionDescription: String
    public var functionalMode: UInt16
    public var operations: [PTPOperationCode]
    public var events: [PTPEventCode]
    public var properties: [PTPPropertyCode]
    public var captureFormats: [UInt16]
    public var imageFormats: [UInt16]
    public var manufacturer: String
    public var model: String
    public var deviceVersion: String
    public var serialNumber: String

    public static let nikonVendorID: UInt32 = 0x0000_000A

    public var isNikon: Bool {
        vendorExtensionID == Self.nikonVendorID || manufacturer.localizedCaseInsensitiveContains("nikon")
    }

    public func supports(_ op: PTPOperationCode) -> Bool { operations.contains(op) }

    public init(decoding data: Data) throws {
        var r = PTPReader(data)
        standardVersion = try r.u16()
        vendorExtensionID = try r.u32()
        vendorExtensionVersion = try r.u16()
        vendorExtensionDescription = try r.string()
        functionalMode = try r.u16()
        operations = try r.array { PTPOperationCode(try $0.u16()) }
        events = try r.array { PTPEventCode(try $0.u16()) }
        properties = try r.array { PTPPropertyCode(try $0.u16()) }
        captureFormats = try r.array { try $0.u16() }
        imageFormats = try r.array { try $0.u16() }
        manufacturer = try r.string()
        model = try r.string()
        deviceVersion = try r.string()
        serialNumber = try r.string()
    }
}

/// GetDevicePropDesc (0x1014) dataset.
public struct PTPPropertyDescriptor: Sendable, Equatable {
    public enum Form: Sendable, Equatable {
        case none
        case range(min: PTPValue, max: PTPValue, step: PTPValue)
        case enumeration([PTPValue])
    }

    public var code: PTPPropertyCode
    public var dataType: PTPDataType
    public var isWritable: Bool
    public var factoryDefault: PTPValue
    public var current: PTPValue
    public var form: Form

    public init(code: PTPPropertyCode, dataType: PTPDataType, isWritable: Bool,
                factoryDefault: PTPValue, current: PTPValue, form: Form) {
        self.code = code
        self.dataType = dataType
        self.isWritable = isWritable
        self.factoryDefault = factoryDefault
        self.current = current
        self.form = form
    }

    public init(decoding data: Data) throws {
        var r = PTPReader(data)
        code = PTPPropertyCode(try r.u16())
        dataType = PTPDataType(try r.u16())
        isWritable = try r.u8() == 1
        factoryDefault = try r.value(of: dataType)
        current = try r.value(of: dataType)
        // Some bodies end the dataset right after the current value; treat that as "no form".
        guard !r.isAtEnd else { form = .none; return }
        switch try r.u8() {
        case 1:
            form = .range(min: try r.value(of: dataType), max: try r.value(of: dataType), step: try r.value(of: dataType))
        case 2:
            let count = Int(try r.u16())
            var values: [PTPValue] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try r.value(of: dataType)) }
            form = .enumeration(values)
        default:
            form = .none
        }
    }

    /// Every value the camera says it accepts right now (enumerations as-is, ranges expanded when small).
    public var allowedValues: [PTPValue]? {
        switch form {
        case let .enumeration(values): return values
        case let .range(min, max, step):
            guard let lo = min.int, let hi = max.int, let st = step.int, st > 0, (hi - lo) / st <= 4096 else { return nil }
            return stride(from: lo, through: hi, by: st).map { dataType.isSigned ? .signed(Int64($0)) : .unsigned(UInt64($0)) }
        case .none: return nil
        }
    }
}

/// A PTP event as reported by Nikon GetEvent (0x90C7) or the interrupt endpoint.
public struct PTPEvent: Sendable, Equatable {
    public var code: PTPEventCode
    public var params: [UInt32]

    public init(code: PTPEventCode, params: [UInt32]) {
        self.code = code
        self.params = params
    }

    /// Nikon GetEvent dataset: UINT16 count, then count × (UINT16 event code, UINT32 parameter).
    public static func decodeNikonEvents(_ data: Data) throws -> [PTPEvent] {
        var r = PTPReader(data)
        guard !r.isAtEnd else { return [] }
        let count = Int(try r.u16())
        var events: [PTPEvent] = []
        for _ in 0..<count {
            events.append(PTPEvent(code: PTPEventCode(try r.u16()), params: [try r.u32()]))
        }
        return events
    }

    /// USB interrupt event container: UINT32 length · UINT16 type (4) · UINT16 code · UINT32 transaction ID · params.
    public static func decodeContainer(_ data: Data) throws -> PTPEvent {
        var r = PTPReader(data)
        let length = Int(try r.u32())
        let type = try r.u16()
        guard type == PTPContainerType.event.rawValue else {
            throw PTPDecodingError.malformed("expected event container, got type \(type)")
        }
        let code = PTPEventCode(try r.u16())
        _ = try r.u32()
        var params: [UInt32] = []
        while r.offset + 4 <= min(length, data.count), params.count < 3 { params.append(try r.u32()) }
        return PTPEvent(code: code, params: params)
    }
}
