import ReflexPTP
import Foundation

/// Thread-safe counters for one live-view measurement window.
nonisolated final class LiveStats: @unchecked Sendable {
    struct Snapshot: Codable, Sendable {
        var seconds: Double
        var requests: Int
        var okResponses: Int
        var busyResponses: Int
        var duplicateFrames: Int
        var badFrames: Int
        var uniqueFrames: Int
        var requestRate: Double
        var uniqueFPS: Double
        var rttMeanMs: Double
        var rttP50Ms: Double
        var rttP95Ms: Double
        var rttMaxMs: Double
        var intervalMeanMs: Double
        var intervalP95Ms: Double
        var intervalStdDevMs: Double
        var payloadMeanKB: Double
        var throughputMBps: Double
        var decodeMeanMs: Double
        var width: Int
        var height: Int
        var headerBytes: Int
    }

    private let lock = NSLock()
    private var start = hostTime()
    private var requests = 0, ok = 0, busy = 0, duplicates = 0, bad = 0
    private var rtts: [Double] = []
    private var uniqueTimes: [Double] = []
    private var payloadBytes = 0
    private var decodeTimes: [Double] = []
    private var width = 0, height = 0, header = 0

    func reset() {
        lock.withLock {
            start = hostTime()
            requests = 0; ok = 0; busy = 0; duplicates = 0; bad = 0
            rtts.removeAll(keepingCapacity: true)
            uniqueTimes.removeAll(keepingCapacity: true)
            decodeTimes.removeAll(keepingCapacity: true)
            payloadBytes = 0
        }
    }

    func response(ok isOK: Bool, busy isBusy: Bool, rtt: Double, bytes: Int) {
        lock.withLock {
            requests += 1
            if isOK { ok += 1; payloadBytes += bytes; rtts.append(rtt) }
            if isBusy { busy += 1 }
        }
    }

    func duplicate() { lock.withLock { duplicates += 1 } }
    func badFrame() { lock.withLock { bad += 1 } }

    func unique(at time: Double, width w: Int, height h: Int, headerBytes: Int) {
        lock.withLock {
            uniqueTimes.append(time)
            width = w; height = h; header = headerBytes
        }
    }

    func decoded(seconds: Double) { lock.withLock { decodeTimes.append(seconds) } }

    func snapshot() -> Snapshot {
        lock.withLock {
            let elapsed = max(hostTime() - start, 0.001)
            let sortedRTT = rtts.sorted()
            let intervals = zip(uniqueTimes.dropFirst(), uniqueTimes).map { $0 - $1 }
            let meanInterval = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
            let variance = intervals.isEmpty ? 0 : intervals.map { ($0 - meanInterval) * ($0 - meanInterval) }.reduce(0, +) / Double(intervals.count)
            let fps = uniqueTimes.count > 1 ? Double(uniqueTimes.count - 1) / (uniqueTimes.last! - uniqueTimes.first!) : 0
            return Snapshot(
                seconds: elapsed,
                requests: requests, okResponses: ok, busyResponses: busy,
                duplicateFrames: duplicates, badFrames: bad, uniqueFrames: uniqueTimes.count,
                requestRate: Double(requests) / elapsed,
                uniqueFPS: fps,
                rttMeanMs: rtts.isEmpty ? 0 : rtts.reduce(0, +) / Double(rtts.count) * 1000,
                rttP50Ms: percentile(sortedRTT, 0.5) * 1000,
                rttP95Ms: percentile(sortedRTT, 0.95) * 1000,
                rttMaxMs: (sortedRTT.last ?? 0) * 1000,
                intervalMeanMs: meanInterval * 1000,
                intervalP95Ms: percentile(intervals.sorted(), 0.95) * 1000,
                intervalStdDevMs: variance.squareRoot() * 1000,
                payloadMeanKB: ok == 0 ? 0 : Double(payloadBytes) / Double(ok) / 1024,
                throughputMBps: Double(payloadBytes) / elapsed / 1_048_576,
                decodeMeanMs: decodeTimes.isEmpty ? 0 : decodeTimes.reduce(0, +) / Double(decodeTimes.count) * 1000,
                width: width, height: height, headerBytes: header)
        }
    }
}

nonisolated func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
    return sorted[index]
}

nonisolated func median(_ values: [Double]) -> Double { percentile(values.sorted(), 0.5) }
