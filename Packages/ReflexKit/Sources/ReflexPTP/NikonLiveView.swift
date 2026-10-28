import Foundation

/// One Nikon GetLiveViewImage (0x9203) payload: a vendor header followed by a baseline JPEG.
///
/// The header layout differs between bodies (128 bytes on older DSLRs, larger on newer ones) and its
/// fields are big-endian, unlike the rest of PTP. We locate the JPEG by its SOI marker rather than
/// trusting a fixed offset, and keep the header bytes for model-specific parsing.
public struct NikonLiveViewFrame: Sendable {
    public let payload: Data
    /// Byte offset of the JPEG SOI marker within `payload` (== header length).
    public let jpegOffset: Int

    public init?(payload: Data, searchLimit: Int = 4096) {
        guard let offset = Self.findJPEGStart(in: payload, limit: searchLimit) else { return nil }
        self.payload = payload
        self.jpegOffset = offset
    }

    public var header: Data { payload.prefix(jpegOffset) }
    public var jpeg: Data { payload.dropFirst(jpegOffset) }
    public var jpegByteCount: Int { payload.count - jpegOffset }

    /// Big-endian UINT16 at `offset` within the header.
    public func headerU16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= jpegOffset else { return nil }
        let i = payload.startIndex + offset
        return UInt16(payload[i]) << 8 | UInt16(payload[i + 1])
    }

    /// Big-endian UINT32 at `offset` within the header.
    public func headerU32(at offset: Int) -> UInt32? {
        guard let hi = headerU16(at: offset), let lo = headerU16(at: offset + 2) else { return nil }
        return UInt32(hi) << 16 | UInt32(lo)
    }

    /// Scans for FF D8 FF (SOI followed by the first marker).
    static func findJPEGStart(in data: Data, limit: Int) -> Int? {
        let end = min(data.count, limit) - 2
        guard end > 0 else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<end where bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF {
                return i
            }
            return nil
        }
    }

    /// Reads width × height from the JPEG's SOF0/SOF2 segment without decoding it.
    public var jpegDimensions: (width: Int, height: Int)? {
        jpeg.withUnsafeBytes { raw -> (Int, Int)? in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 2
            while i + 9 < b.count {
                guard b[i] == 0xFF else { return nil }
                let marker = b[i + 1]
                if marker == 0xD8 || (0xD0...0xD7).contains(marker) || marker == 0x01 { i += 2; continue }
                let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
                if (0xC0...0xC3).contains(marker) {
                    let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
                    let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                    return (w, h)
                }
                if marker == 0xDA { return nil }
                i += 2 + length
            }
            return nil
        }
    }
}
