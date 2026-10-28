import Foundation

public enum PTPDecodingError: Error, Equatable, CustomStringConvertible {
    case truncated(needed: Int, at: Int, length: Int)
    case unsupportedType(UInt16)
    case malformed(String)

    public var description: String {
        switch self {
        case let .truncated(needed, at, length): "PTP data truncated: needed \(needed) bytes at \(at) of \(length)"
        case let .unsupportedType(type): String(format: "unsupported PTP data type 0x%04X", type)
        case let .malformed(why): "malformed PTP data: \(why)"
        }
    }
}

/// A decoded PTP value. Integers are widened; 128-bit values stay as raw little-endian bytes.
public enum PTPValue: Hashable, Sendable, CustomStringConvertible {
    case signed(Int64)
    case unsigned(UInt64)
    case wide(Data)
    case string(String)
    case array([PTPValue])

    public var int: Int? {
        switch self {
        case let .signed(v): Int(exactly: v)
        case let .unsigned(v): Int(exactly: v)
        default: nil
        }
    }

    public var description: String {
        switch self {
        case let .signed(v): "\(v)"
        case let .unsigned(v): "\(v)"
        case let .wide(d): "0x" + d.reversed().map { String(format: "%02x", $0) }.joined()
        case let .string(s): "\"\(s)\""
        case let .array(a): "[" + a.map(\.description).joined(separator: ", ") + "]"
        }
    }
}

/// Little-endian cursor over a PTP dataset.
public struct PTPReader {
    public let data: Data
    public private(set) var offset: Int = 0

    public init(_ data: Data) { self.data = data }

    public var remaining: Int { data.count - offset }
    public var isAtEnd: Bool { remaining <= 0 }

    private mutating func take(_ n: Int) throws -> Data.SubSequence {
        guard n >= 0, remaining >= n else { throw PTPDecodingError.truncated(needed: n, at: offset, length: data.count) }
        let start = data.startIndex + offset
        offset += n
        return data[start..<start + n]
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let bytes = try take(MemoryLayout<T>.size)
        var value: T = 0
        for (i, byte) in bytes.enumerated() { value |= T(truncatingIfNeeded: byte) << (8 * i) }
        return value
    }

    public mutating func u8() throws -> UInt8 { try integer(UInt8.self) }
    public mutating func u16() throws -> UInt16 { try integer(UInt16.self) }
    public mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
    public mutating func u64() throws -> UInt64 { try integer(UInt64.self) }
    public mutating func i8() throws -> Int8 { try integer(Int8.self) }
    public mutating func i16() throws -> Int16 { try integer(Int16.self) }
    public mutating func i32() throws -> Int32 { try integer(Int32.self) }
    public mutating func i64() throws -> Int64 { try integer(Int64.self) }
    public mutating func bytes(_ n: Int) throws -> Data { Data(try take(n)) }

    /// PTP string: UINT8 character count (including the terminating NUL), then UTF-16LE code units.
    public mutating func string() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// PTP array: UINT32 element count, then the elements.
    public mutating func array<T>(_ element: (inout PTPReader) throws -> T) throws -> [T] {
        let count = Int(try u32())
        guard count <= remaining else { throw PTPDecodingError.malformed("array count \(count) exceeds \(remaining) bytes") }
        var out: [T] = []
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(try element(&self)) }
        return out
    }

    public mutating func value(of type: PTPDataType) throws -> PTPValue {
        if type == .string { return .string(try string()) }
        if type.isArray {
            let element = type.element
            return .array(try array { try $0.value(of: element) })
        }
        switch type {
        case .int8: return .signed(Int64(try i8()))
        case .uint8: return .unsigned(UInt64(try u8()))
        case .int16: return .signed(Int64(try i16()))
        case .uint16: return .unsigned(UInt64(try u16()))
        case .int32: return .signed(Int64(try i32()))
        case .uint32: return .unsigned(UInt64(try u32()))
        case .int64: return .signed(try i64())
        case .uint64: return .unsigned(try u64())
        case .int128, .uint128: return .wide(try bytes(16))
        default: throw PTPDecodingError.unsupportedType(type.rawValue)
        }
    }
}

/// Little-endian PTP encoder.
public struct PTPWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func put<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func put(string: String) {
        guard !string.isEmpty else { data.append(0); return }
        let units = Array(string.utf16) + [0]
        data.append(UInt8(min(units.count, 255)))
        for unit in units.prefix(255) { put(unit) }
    }

    public mutating func put(_ value: PTPValue, as type: PTPDataType) throws {
        switch (value, type) {
        case let (.string(s), .string): put(string: s)
        case let (.array(items), t) where t.isArray:
            put(UInt32(items.count))
            for item in items { try put(item, as: t.element) }
        case let (.wide(d), t) where t.byteWidth == 16 && d.count == 16: data.append(d)
        case (.signed, _), (.unsigned, _):
            guard let width = type.byteWidth, width <= 8 else { throw PTPDecodingError.unsupportedType(type.rawValue) }
            let bits: UInt64 = switch value {
            case let .signed(v): UInt64(bitPattern: v)
            case let .unsigned(v): v
            default: 0
            }
            for i in 0..<width { data.append(UInt8(truncatingIfNeeded: bits >> (8 * i))) }
        default:
            throw PTPDecodingError.malformed("cannot encode \(value) as \(type)")
        }
    }

    public static func encode(_ value: PTPValue, as type: PTPDataType) throws -> Data {
        var writer = PTPWriter()
        try writer.put(value, as: type)
        return writer.data
    }
}
