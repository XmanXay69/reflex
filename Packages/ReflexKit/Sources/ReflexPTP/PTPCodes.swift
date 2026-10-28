import Foundation

/// A 16-bit PTP code with a readable name for logs and reports. Codes are structs (not enums)
/// so values the camera reports that we have no name for still round-trip.
public protocol PTPCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible where RawValue == UInt16 {
    static var names: [UInt16: String] { get }
}

extension PTPCode {
    public var name: String? { Self.names[rawValue] }
    public var hex: String { String(format: "0x%04X", rawValue) }
    public var description: String { name.map { "\($0) (\(hex))" } ?? hex }
}

// MARK: - Operations

public struct PTPOperationCode: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let getDeviceInfo = Self(0x1001)
    public static let openSession = Self(0x1002)
    public static let closeSession = Self(0x1003)
    public static let getDevicePropDesc = Self(0x1014)
    public static let getDevicePropValue = Self(0x1015)
    public static let setDevicePropValue = Self(0x1016)

    // Nikon vendor extension
    public static let nikonAfDrive = Self(0x90C1)
    public static let nikonChangeCameraMode = Self(0x90C2)
    public static let nikonGetEvent = Self(0x90C7)
    public static let nikonDeviceReady = Self(0x90C8)
    public static let nikonGetVendorPropCodes = Self(0x90CA)
    public static let nikonStartLiveView = Self(0x9201)
    public static let nikonEndLiveView = Self(0x9202)
    public static let nikonGetLiveViewImage = Self(0x9203)
    public static let nikonMfDrive = Self(0x9204)
    public static let nikonChangeAfArea = Self(0x9205)
    public static let nikonAfDriveCancel = Self(0x9206)
    public static let nikonGetEventEx = Self(0x941C)
    public static let nikonGetLiveViewImageEx = Self(0x9428)

    public static let names: [UInt16: String] = [
        0x1001: "GetDeviceInfo", 0x1002: "OpenSession", 0x1003: "CloseSession",
        0x1014: "GetDevicePropDesc", 0x1015: "GetDevicePropValue", 0x1016: "SetDevicePropValue",
        0x90C1: "Nikon.AfDrive", 0x90C2: "Nikon.ChangeCameraMode", 0x90C7: "Nikon.GetEvent",
        0x90C8: "Nikon.DeviceReady", 0x90CA: "Nikon.GetVendorPropCodes",
        0x9201: "Nikon.StartLiveView", 0x9202: "Nikon.EndLiveView", 0x9203: "Nikon.GetLiveViewImage",
        0x9204: "Nikon.MfDrive", 0x9205: "Nikon.ChangeAfArea", 0x9206: "Nikon.AfDriveCancel",
        0x941C: "Nikon.GetEventEx", 0x9428: "Nikon.GetLiveViewImageEx",
    ]
}

// MARK: - Responses

public struct PTPResponseCode: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public var isOK: Bool { self == .ok }

    public static let ok = Self(0x2001)
    public static let generalError = Self(0x2002)
    public static let sessionNotOpen = Self(0x2003)
    public static let operationNotSupported = Self(0x2005)
    public static let parameterNotSupported = Self(0x2006)
    public static let devicePropNotSupported = Self(0x200A)
    public static let accessDenied = Self(0x200F)
    public static let deviceBusy = Self(0x2019)
    public static let invalidDevicePropFormat = Self(0x201B)
    public static let invalidDevicePropValue = Self(0x201C)
    public static let invalidParameter = Self(0x201D)

    public static let nikonHardwareError = Self(0xA001)
    public static let nikonOutOfFocus = Self(0xA002)
    public static let nikonInvalidStatus = Self(0xA004)
    public static let nikonSetPropertyNotSupported = Self(0xA005)
    public static let nikonNotLiveView = Self(0xA00B)
    public static let nikonMfDriveStepEnd = Self(0xA00C)
    public static let nikonMfDriveStepInsufficiency = Self(0xA00E)

    public static let names: [UInt16: String] = [
        0x2001: "OK", 0x2002: "GeneralError", 0x2003: "SessionNotOpen", 0x2004: "InvalidTransactionID",
        0x2005: "OperationNotSupported", 0x2006: "ParameterNotSupported", 0x2007: "IncompleteTransfer",
        0x200A: "DevicePropNotSupported", 0x200F: "AccessDenied", 0x2019: "DeviceBusy",
        0x201B: "InvalidDevicePropFormat", 0x201C: "InvalidDevicePropValue", 0x201D: "InvalidParameter",
        0x201E: "SessionAlreadyOpen", 0x201F: "TransactionCancelled",
        0xA001: "Nikon.HardwareError", 0xA002: "Nikon.OutOfFocus", 0xA003: "Nikon.ChangeCameraModeFailed",
        0xA004: "Nikon.InvalidStatus", 0xA005: "Nikon.SetPropertyNotSupported", 0xA008: "Nikon.ShutterSpeedBulb",
        0xA009: "Nikon.MirrorUpSequence", 0xA00A: "Nikon.CameraModeNotAdjustFNumber", 0xA00B: "Nikon.NotLiveView",
        0xA00C: "Nikon.MfDriveStepEnd", 0xA00E: "Nikon.MfDriveStepInsufficiency",
    ]
}

// MARK: - Device properties

public struct PTPPropertyCode: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    // Standard (PIMA 15740)
    public static let batteryLevel = Self(0x5001)
    public static let whiteBalance = Self(0x5005)
    public static let fNumber = Self(0x5007)
    public static let focalLength = Self(0x5008)
    public static let focusMode = Self(0x500A)
    public static let exposureMeteringMode = Self(0x500B)
    public static let exposureTime = Self(0x500D)
    public static let exposureProgramMode = Self(0x500E)
    public static let exposureIndex = Self(0x500F)
    public static let exposureBiasCompensation = Self(0x5010)
    public static let focusMeteringMode = Self(0x501C)

    // Nikon
    public static let nikonWhiteBalanceColorTemperature = Self(0xD01E)
    public static let nikonISOAuto = Self(0xD054)
    public static let nikonLiveViewAFArea = Self(0xD05D)
    public static let nikonLiveViewAFFocus = Self(0xD061)
    public static let nikonExposureIndexEx = Self(0xD0B4)
    public static let nikonLensID = Self(0xD0E0)
    public static let nikonExposureTime = Self(0xD100)
    public static let nikonACPower = Self(0xD101)
    public static let nikonRecordingMedia = Self(0xD10B)
    public static let nikonActiveDLighting = Self(0xD14E)
    public static let nikonAutofocusMode = Self(0xD161)
    public static let nikonLiveViewMode = Self(0xD1A0)
    public static let nikonLiveViewStatus = Self(0xD1A2)
    public static let nikonLiveViewImageZoomRatio = Self(0xD1A3)
    public static let nikonLiveViewProhibitCondition = Self(0xD1A4)
    public static let nikonLiveViewExposurePreview = Self(0xD1A5)
    public static let nikonLiveViewSelector = Self(0xD1A6)
    public static let nikonLiveViewWhiteBalance = Self(0xD1A7)
    public static let nikonMovieShutterSpeed = Self(0xD1A8)
    public static let nikonMovieFNumber = Self(0xD1A9)
    public static let nikonMovieISO = Self(0xD1AA)
    public static let nikonMovieExposureBiasCompensation = Self(0xD1AB)
    public static let nikonLiveViewImageSize = Self(0xD1AC)
    public static let nikonLiveViewImageStatus = Self(0xD1BB)
    public static let nikonLiveViewImageCompression = Self(0xD1BC)
    public static let nikonActivePicCtrlItem = Self(0xD200)
    public static let nikonMovieWhiteBalance = Self(0xD23A)

    public static let names: [UInt16: String] = [
        0x5001: "BatteryLevel", 0x5003: "ImageSize", 0x5004: "CompressionSetting", 0x5005: "WhiteBalance",
        0x5007: "FNumber", 0x5008: "FocalLength", 0x500A: "FocusMode", 0x500B: "ExposureMeteringMode",
        0x500C: "FlashMode", 0x500D: "ExposureTime", 0x500E: "ExposureProgramMode", 0x500F: "ExposureIndex",
        0x5010: "ExposureBiasCompensation", 0x5011: "DateTime", 0x5013: "StillCaptureMode",
        0x501C: "FocusMeteringMode",
        0xD01E: "Nikon.WhiteBalanceColorTemperature", 0xD054: "Nikon.ISOAuto", 0xD05D: "Nikon.LiveViewAFArea",
        0xD061: "Nikon.LiveViewAFFocus", 0xD0B4: "Nikon.ExposureIndexEx", 0xD0E0: "Nikon.LensID",
        0xD100: "Nikon.ExposureTime", 0xD101: "Nikon.ACPower", 0xD10B: "Nikon.RecordingMedia",
        0xD14E: "Nikon.ActiveDLighting", 0xD161: "Nikon.AutofocusMode",
        0xD1A0: "Nikon.LiveViewMode", 0xD1A2: "Nikon.LiveViewStatus", 0xD1A3: "Nikon.LiveViewImageZoomRatio",
        0xD1A4: "Nikon.LiveViewProhibitCondition", 0xD1A5: "Nikon.LiveViewExposurePreview",
        0xD1A6: "Nikon.LiveViewSelector", 0xD1A7: "Nikon.LiveViewWhiteBalance",
        0xD1A8: "Nikon.MovieShutterSpeed", 0xD1A9: "Nikon.MovieFNumber", 0xD1AA: "Nikon.MovieISO",
        0xD1AB: "Nikon.MovieExposureBiasCompensation", 0xD1AC: "Nikon.LiveViewImageSize",
        0xD1BB: "Nikon.LiveViewImageStatus", 0xD1BC: "Nikon.LiveViewImageCompression",
        0xD200: "Nikon.ActivePicCtrlItem", 0xD23A: "Nikon.MovieWhiteBalance",
    ]
}

// MARK: - Events

public struct PTPEventCode: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let objectAdded = Self(0x4002)
    public static let devicePropChanged = Self(0x4006)
    public static let captureComplete = Self(0x400D)

    public static let names: [UInt16: String] = [
        0x4002: "ObjectAdded", 0x4006: "DevicePropChanged", 0x400D: "CaptureComplete",
        0xC101: "Nikon.ObjectAddedInSDRAM", 0xC102: "Nikon.CaptureCompleteRecInSdram",
    ]
}

// MARK: - Data types

public struct PTPDataType: PTPCode {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let int8 = Self(0x0001), uint8 = Self(0x0002)
    public static let int16 = Self(0x0003), uint16 = Self(0x0004)
    public static let int32 = Self(0x0005), uint32 = Self(0x0006)
    public static let int64 = Self(0x0007), uint64 = Self(0x0008)
    public static let int128 = Self(0x0009), uint128 = Self(0x000A)
    public static let string = Self(0xFFFF)

    public var isArray: Bool { rawValue & 0x4000 != 0 && rawValue != 0xFFFF }
    public var element: PTPDataType { Self(rawValue & ~0x4000) }
    public var isSigned: Bool { [0x0001, 0x0003, 0x0005, 0x0007, 0x0009].contains(rawValue) }

    /// Width in bytes of a scalar; nil for strings, arrays and unknown types.
    public var byteWidth: Int? {
        switch rawValue {
        case 0x0001, 0x0002: 1
        case 0x0003, 0x0004: 2
        case 0x0005, 0x0006: 4
        case 0x0007, 0x0008: 8
        case 0x0009, 0x000A: 16
        default: nil
        }
    }

    public static let names: [UInt16: String] = [
        0x0001: "INT8", 0x0002: "UINT8", 0x0003: "INT16", 0x0004: "UINT16", 0x0005: "INT32",
        0x0006: "UINT32", 0x0007: "INT64", 0x0008: "UINT64", 0x0009: "INT128", 0x000A: "UINT128",
        0xFFFF: "STR",
    ]
}
