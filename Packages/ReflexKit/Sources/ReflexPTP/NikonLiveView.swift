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

    /// Decoded header fields, or nil if the header is too short to hold them.
    public var info: NikonLiveViewInfo? { NikonLiveViewInfo(frame: self) }

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

/// Fields at the start of the GetLiveViewImage header, all big-endian. Layout verified on a D780
/// (firmware 1.02, 384-byte header) in both photo and movie live view:
///
///     0  UINT32  header length after this field (376)
///     4  UINT32  JPEG byte count
///     8  UINT16  JPEG width, height
///    12  UINT16  sensor ("whole") width, height  — coordinate space for ChangeAfArea
///    16  UINT16  display area width, height
///    20  UINT16  display area center x, y
///    24  UINT16  AF frame width, height
///    28  UINT16  AF frame center x, y
public struct NikonLiveViewInfo: Sendable, Equatable {
    public var jpegByteCount: Int
    public var jpegWidth: Int
    public var jpegHeight: Int
    public var sensorWidth: Int
    public var sensorHeight: Int
    public var displayWidth: Int
    public var displayHeight: Int
    public var displayCenterX: Int
    public var displayCenterY: Int
    public var afWidth: Int
    public var afHeight: Int
    public var afCenterX: Int
    public var afCenterY: Int

    init?(frame: NikonLiveViewFrame) {
        guard frame.jpegOffset >= 32,
              let jpegBytes = frame.headerU32(at: 4),
              let w = frame.headerU16(at: 8), let h = frame.headerU16(at: 10),
              let sw = frame.headerU16(at: 12), let sh = frame.headerU16(at: 14),
              let dw = frame.headerU16(at: 16), let dh = frame.headerU16(at: 18),
              let dx = frame.headerU16(at: 20), let dy = frame.headerU16(at: 22),
              let aw = frame.headerU16(at: 24), let ah = frame.headerU16(at: 26),
              let ax = frame.headerU16(at: 28), let ay = frame.headerU16(at: 30),
              sw > 0, sh > 0 else { return nil }
        jpegByteCount = Int(jpegBytes)
        jpegWidth = Int(w); jpegHeight = Int(h)
        sensorWidth = Int(sw); sensorHeight = Int(sh)
        displayWidth = Int(dw); displayHeight = Int(dh)
        displayCenterX = Int(dx); displayCenterY = Int(dy)
        afWidth = Int(aw); afHeight = Int(ah)
        afCenterX = Int(ax); afCenterY = Int(ay)
    }
}
