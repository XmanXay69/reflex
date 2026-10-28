import Testing
@testable import ReflexCamera

@Suite struct FramePacerTests {
    @Test func disabledNeverWaits() {
        var pacer = FramePacer(isEnabled: false)
        pacer.newFrame(requestedAt: 1.0)
        #expect(pacer.delay(now: 1.001, lastWasRepeat: false) == 0)
        #expect(pacer.delay(now: 1.001, lastWasRepeat: true) == 0)
    }

    @Test func waitsUntilJustBeforeTheNextFrame() {
        var pacer = FramePacer()
        #expect(pacer.delay(now: 0, lastWasRepeat: false) == 0) // no phase yet: ask now
        pacer.newFrame(requestedAt: 10.0)
        let delay = pacer.delay(now: 10.010, lastWasRepeat: false)
        #expect(abs(delay - (1.0 / 30 - pacer.lead - 0.010)) < 1e-9)
    }

    @Test func retriesQuicklyAfterARepeat() {
        let pacer = FramePacer()
        #expect(pacer.delay(now: 0, lastWasRepeat: true) == pacer.retry)
    }

    @Test func neverReturnsNegative() {
        var pacer = FramePacer()
        pacer.newFrame(requestedAt: 0)
        #expect(pacer.delay(now: 5, lastWasRepeat: false) == 0)
    }

    @Test func learnsTheCameraPeriod() {
        var pacer = FramePacer()
        for i in 0..<200 { pacer.newFrame(requestedAt: Double(i) * 0.040) }
        #expect(abs(pacer.estimatedPeriod - 0.040) < 0.0005)
    }

    @Test func ignoresStalls() {
        var pacer = FramePacer()
        pacer.newFrame(requestedAt: 0)
        pacer.newFrame(requestedAt: 0.5)
        #expect(abs(pacer.estimatedPeriod - 1.0 / 30) < 1e-9)
    }
}
