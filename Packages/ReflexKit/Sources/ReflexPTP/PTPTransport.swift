import Foundation

public enum PTPError: Error, CustomStringConvertible, Equatable {
    /// The camera answered with a non-OK response code.
    case response(PTPResponseCode, operation: PTPOperationCode)
    /// The OS transport failed (ImageCaptureCore error, USB error, ...).
    case transport(String)
    case disconnected
    case timedOut(PTPOperationCode)

    public var description: String {
        switch self {
        case let .response(code, op): "\(op.name ?? op.hex) failed: \(code)"
        case let .transport(why): "transport error: \(why)"
        case .disconnected: "camera disconnected"
        case let .timedOut(op): "\(op.name ?? op.hex) timed out"
        }
    }

    public var responseCode: PTPResponseCode? {
        if case let .response(code, _) = self { return code }
        return nil
    }
}

/// One completed PTP transaction.
public struct PTPTransaction: Sendable {
    public var response: PTPResponse
    /// Data-phase payload (camera → host), without any container header.
    public var data: Data
    /// Host monotonic time (seconds) when the request was handed to the OS, and when the response arrived.
    public var sentAt: Double
    public var completedAt: Double

    public var roundTrip: Double { completedAt - sentAt }

    public init(response: PTPResponse, data: Data, sentAt: Double, completedAt: Double) {
        self.response = response
        self.data = data
        self.sentAt = sentAt
        self.completedAt = completedAt
    }
}

/// Moves PTP transactions to and from a camera. Implementations must run transactions strictly
/// one at a time, in call order: PTP has no pipelining, and ordering keeps timing measurements honest.
/// Swappable: ImageCaptureCore passthrough today; libgphoto2/libusb could slot in behind the same protocol.
public protocol PTPTransport: AnyObject, Sendable {
    func transact(_ code: PTPOperationCode, params: [UInt32], dataOut: Data?) async throws -> PTPTransaction
}

/// Monotonic host time in seconds (mach_absolute_time based; same clock as CACurrentMediaTime).
@inline(__always)
public func hostTime() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

// MARK: - Typed helpers

extension PTPTransport {
    /// Runs a transaction and throws unless the camera answers OK.
    @discardableResult
    public func run(_ code: PTPOperationCode, _ params: [UInt32] = [], dataOut: Data? = nil) async throws -> PTPTransaction {
        let t = try await transact(code, params: params, dataOut: dataOut)
        guard t.response.code.isOK else { throw PTPError.response(t.response.code, operation: code) }
        return t
    }

    public func deviceInfo() async throws -> PTPDeviceInfo {
        try PTPDeviceInfo(decoding: try await run(.getDeviceInfo).data)
    }

    public func propertyDescriptor(_ code: PTPPropertyCode) async throws -> PTPPropertyDescriptor {
        try PTPPropertyDescriptor(decoding: try await run(.getDevicePropDesc, [UInt32(code.rawValue)]).data)
    }

    public func propertyValue(_ code: PTPPropertyCode, type: PTPDataType) async throws -> PTPValue {
        var r = PTPReader(try await run(.getDevicePropValue, [UInt32(code.rawValue)]).data)
        return try r.value(of: type)
    }

    @discardableResult
    public func setPropertyValue(_ code: PTPPropertyCode, _ value: PTPValue, type: PTPDataType) async throws -> PTPTransaction {
        try await run(.setDevicePropValue, [UInt32(code.rawValue)], dataOut: try PTPWriter.encode(value, as: type))
    }

    /// Nikon: vendor property codes that some bodies leave out of DeviceInfo.
    public func nikonVendorPropertyCodes() async throws -> [PTPPropertyCode] {
        var r = PTPReader(try await run(.nikonGetVendorPropCodes).data)
        return try r.array { PTPPropertyCode(try $0.u16()) }
    }

    public func nikonEvents() async throws -> [PTPEvent] {
        try PTPEvent.decodeNikonEvents(try await run(.nikonGetEvent).data)
    }

    /// Nikon: polls DeviceReady until the camera stops answering DeviceBusy.
    public func nikonWaitUntilReady(timeout: Double = 3, interval: Double = 0.02) async throws {
        let deadline = hostTime() + timeout
        while true {
            let t = try await transact(.nikonDeviceReady, params: [], dataOut: nil)
            if t.response.code.isOK { return }
            guard t.response.code == .deviceBusy, hostTime() < deadline else {
                if t.response.code == .deviceBusy { throw PTPError.timedOut(.nikonDeviceReady) }
                throw PTPError.response(t.response.code, operation: .nikonDeviceReady)
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
