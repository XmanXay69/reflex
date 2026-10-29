import Testing
@testable import ReflexCamera

@Suite struct CameraTypesTests {
    @Test func modeDialReasonIsActionable() {
        #expect(NikonLiveView.prohibitReasons(1 << 31) == ["turn the mode dial to P, S, A or M"])
    }

    @Test func multipleReasonsAreAllReported() {
        let reasons = NikonLiveView.prohibitReasons(1 << 8 | 1 << 17)
        #expect(reasons.contains("the battery is empty"))
        #expect(reasons.contains("the camera is too hot"))
        #expect(reasons.count == 2)
    }

    @Test func refusalMessageReadsAsASentence() {
        #expect(CameraError.liveViewRefused(["insert a memory card"]).description
            == "Live view unavailable: insert a memory card.")
    }

    @Test func usbSpeedLabels() {
        #expect(USBLinkSpeed(bitsPerSecond: 480_000_000).label == "USB 2.0")
        #expect(USBLinkSpeed(bitsPerSecond: 480_000_000).isUSB2OrSlower)
        #expect(USBLinkSpeed(bitsPerSecond: 5_000_000_000).label == "USB 5 Gb/s")
        #expect(!USBLinkSpeed(bitsPerSecond: 5_000_000_000).isUSB2OrSlower)
    }

    @Test func qualityLevelsStayWithinTheCameraRange() {
        #expect(LiveViewQuality.allCases.map(\.cameraLevel) == [1, 3, 5])
    }
}

@Suite struct ControlFormatterTests {
    @Test func photoShutterIsInTenThousandths() {
        #expect(ControlFormatter.photoShutter(400) == "1/25")
        #expect(ControlFormatter.photoShutter(166) == "1/60")
        #expect(ControlFormatter.photoShutter(62) == "1/160")
        #expect(ControlFormatter.photoShutter(31) == "1/320")
        #expect(ControlFormatter.photoShutter(12) == "1/800")
        #expect(ControlFormatter.photoShutter(1) == "1/8000")
        #expect(ControlFormatter.photoShutter(3333) == "1/3")
        #expect(ControlFormatter.photoShutter(10_000) == "1\"")
        #expect(ControlFormatter.photoShutter(13_000) == "1.3\"")
        #expect(ControlFormatter.photoShutter(0xFFFF_FFFF) == "Bulb")
    }

    @Test func movieShutterIsAFraction() {
        #expect(ControlFormatter.movieShutter(0x0001_0032) == "1/50")
    }

    @Test func apertureAndCompensation() {
        #expect(ControlFormatter.label(.aperture, mode: .photo, value: .unsigned(180)) == "f/1.8")
        #expect(ControlFormatter.label(.aperture, mode: .photo, value: .unsigned(1100)) == "f/11")
        #expect(ControlFormatter.label(.compensation, mode: .photo, value: .signed(-1333)) == "-1.3 EV")
        #expect(ControlFormatter.label(.compensation, mode: .photo, value: .signed(0)) == "0 EV")
        #expect(ControlFormatter.label(.mode, mode: .photo, value: .unsigned(1)) == "M")
    }

    @Test func photoAndMovieUseDifferentProperties() {
        #expect(CameraControl.iso.property(for: .photo).code.rawValue == 0x500F)
        #expect(CameraControl.iso.property(for: .movie).code.rawValue == 0xD1AA)
        #expect(CameraControl.shutter.property(for: .movie).code.rawValue == 0xD1A8)
    }
}
