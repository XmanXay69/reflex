import Foundation
import Testing
@testable import ReflexPTP

@Suite struct PTPCodingTests {
    @Test func commandContainerLayout() {
        let data = PTPCommand(.getDevicePropDesc, transactionID: 7, params: [0x5005]).encoded()
        #expect(Array(data) == [16, 0, 0, 0, 1, 0, 0x14, 0x10, 7, 0, 0, 0, 0x05, 0x50, 0, 0])
    }

    @Test func responseContainerDecodes() throws {
        let bytes: [UInt8] = [16, 0, 0, 0, 3, 0, 0x01, 0x20, 9, 0, 0, 0, 0x2A, 0, 0, 0]
        let response = try PTPResponse.decode(Data(bytes))
        #expect(response.code == .ok)
        #expect(response.transactionID == 9)
        #expect(response.params == [42])
    }

    @Test func dataPhaseHeaderIsStrippedOnlyWhenPresent() {
        let payload: [UInt8] = [0xAA, 0xBB]
        let container: [UInt8] = [14, 0, 0, 0, 2, 0, 0x15, 0x10, 1, 0, 0, 0] + payload
        #expect(Array(ptpPayload(fromDataPhase: Data(container))) == payload)
        #expect(Array(ptpPayload(fromDataPhase: Data(payload))) == payload)
    }

    @Test func stringRoundTrip() throws {
        var w = PTPWriter()
        w.put(string: "D780")
        var r = PTPReader(w.data)
        #expect(try r.string() == "D780")
        #expect(r.isAtEnd)
    }

    @Test func enumerationDescriptor() throws {
        // WhiteBalance (0x5005), UINT16, get/set, default 2, current 4, enum [2, 4, 6]
        var w = PTPWriter()
        w.put(UInt16(0x5005)); w.put(UInt16(0x0004)); w.put(UInt8(1))
        w.put(UInt16(2)); w.put(UInt16(4))
        w.put(UInt8(2)); w.put(UInt16(3)); w.put(UInt16(2)); w.put(UInt16(4)); w.put(UInt16(6))
        let desc = try PTPPropertyDescriptor(decoding: w.data)
        #expect(desc.code == .whiteBalance)
        #expect(desc.isWritable)
        #expect(desc.current == .unsigned(4))
        #expect(desc.form == .enumeration([.unsigned(2), .unsigned(4), .unsigned(6)]))
    }

    @Test func signedRangeDescriptorExpands() throws {
        // ExposureBiasCompensation (0x5010), INT16, range -3000...3000 step 1000
        var w = PTPWriter()
        w.put(UInt16(0x5010)); w.put(UInt16(0x0003)); w.put(UInt8(1))
        w.put(Int16(0)); w.put(Int16(-1000))
        w.put(UInt8(1)); w.put(Int16(-3000)); w.put(Int16(3000)); w.put(Int16(1000))
        let desc = try PTPPropertyDescriptor(decoding: w.data)
        #expect(desc.current == .signed(-1000))
        #expect(desc.allowedValues == [-3000, -2000, -1000, 0, 1000, 2000, 3000].map { .signed($0) })
    }

    @Test func signedValueEncodesTwosComplement() throws {
        #expect(Array(try PTPWriter.encode(.signed(-1000), as: .int16)) == [0x18, 0xFC])
    }

    @Test func nikonEventList() throws {
        var w = PTPWriter()
        w.put(UInt16(2))
        w.put(UInt16(0x4006)); w.put(UInt32(0x5005))
        w.put(UInt16(0x4006)); w.put(UInt32(0xD1A2))
        let events = try PTPEvent.decodeNikonEvents(w.data)
        #expect(events == [PTPEvent(code: .devicePropChanged, params: [0x5005]),
                           PTPEvent(code: .devicePropChanged, params: [0xD1A2])])
    }

    @Test func truncatedDataThrows() {
        var r = PTPReader(Data([0x01]))
        #expect(throws: PTPDecodingError.self) { try r.u16() }
    }
}

@Suite struct NikonLiveViewTests {
    /// Minimal JPEG prefix: SOI, then an SOF0 segment declaring 1024 × 576.
    static let jpegStub: [UInt8] = [0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x02, 0x40, 0x04, 0x00, 0x03,
                                    0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xFF, 0xD9]

    @Test func findsJPEGAfterHeader() throws {
        var header = [UInt8](repeating: 0, count: 384)
        header[0] = 0x04; header[1] = 0x00 // 1024, big-endian
        let frame = try #require(NikonLiveViewFrame(payload: Data(header + Self.jpegStub)))
        #expect(frame.jpegOffset == 384)
        #expect(frame.headerU16(at: 0) == 1024)
        #expect(frame.jpegByteCount == Self.jpegStub.count)
        #expect(frame.jpegDimensions?.width == 1024)
        #expect(frame.jpegDimensions?.height == 576)
    }

    @Test func rejectsPayloadWithoutJPEG() {
        #expect(NikonLiveViewFrame(payload: Data(repeating: 0, count: 600)) == nil)
    }
}
