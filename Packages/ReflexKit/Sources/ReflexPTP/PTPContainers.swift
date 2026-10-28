import Foundation

/// USB container types (PIMA 15740 / USB Still Image Capture Device class).
public enum PTPContainerType: UInt16, Sendable {
    case command = 1, data = 2, response = 3, event = 4
}

/// A PTP operation request, encoded as a USB command container:
/// UINT32 length · UINT16 type (1) · UINT16 code · UINT32 transaction ID · up to five UINT32 parameters.
public struct PTPCommand: Sendable, Equatable {
    public var code: PTPOperationCode
    public var transactionID: UInt32
    public var params: [UInt32]

    public init(_ code: PTPOperationCode, transactionID: UInt32, params: [UInt32] = []) {
        precondition(params.count <= 5, "PTP allows at most five operation parameters")
        self.code = code
        self.transactionID = transactionID
        self.params = params
    }

    public func encoded() -> Data {
        var w = PTPWriter()
        w.put(UInt32(12 + 4 * params.count))
        w.put(PTPContainerType.command.rawValue)
        w.put(code.rawValue)
        w.put(transactionID)
        for p in params { w.put(p) }
        return w.data
    }
}

/// A PTP response container: UINT32 length · UINT16 type (3) · UINT16 response code · UINT32 transaction ID · params.
public struct PTPResponse: Sendable, Equatable {
    public var code: PTPResponseCode
    public var transactionID: UInt32
    public var params: [UInt32]

    public init(code: PTPResponseCode, transactionID: UInt32, params: [UInt32] = []) {
        self.code = code
        self.transactionID = transactionID
        self.params = params
    }

    public static func decode(_ data: Data) throws -> PTPResponse {
        var r = PTPReader(data)
        let length = Int(try r.u32())
        let type = try r.u16()
        guard type == PTPContainerType.response.rawValue else {
            throw PTPDecodingError.malformed("expected response container, got type \(type)")
        }
        let code = PTPResponseCode(try r.u16())
        let tid = try r.u32()
        var params: [UInt32] = []
        let end = min(length, data.count)
        while r.offset + 4 <= end, params.count < 5 { params.append(try r.u32()) }
        return PTPResponse(code: code, transactionID: tid, params: params)
    }
}

/// Strips a USB data-container header if one is present. Some transports hand back the
/// raw payload, others the full container; both are accepted.
public func ptpPayload(fromDataPhase data: Data) -> Data {
    guard data.count >= 12 else { return data }
    var r = PTPReader(data)
    guard let length = try? r.u32(), let type = try? r.u16() else { return data }
    if type == PTPContainerType.data.rawValue, Int(length) == data.count {
        return data.subdata(in: data.startIndex + 12..<data.endIndex)
    }
    return data
}
