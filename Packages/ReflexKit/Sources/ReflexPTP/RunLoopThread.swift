import Foundation

/// A dedicated thread with a live run loop. ImageCaptureCore delivers callbacks through the run loop
/// of the thread that made the request, so all camera I/O is issued from here: it keeps camera traffic
/// off the main thread (no UI-induced jitter) and gives callbacks a run loop that is always spinning.
public final class RunLoopThread: Thread, @unchecked Sendable {
    private var runLoop: CFRunLoop?
    private let started = DispatchSemaphore(value: 0)

    public init(name: String, qos: QualityOfService = .userInteractive) {
        super.init()
        self.name = name
        self.qualityOfService = qos
        start()
        started.wait()
    }

    public override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A port keeps the run loop from returning immediately when it has no other sources.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        started.signal()
        while !isCancelled {
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
    }

    /// Runs `block` on this thread's run loop, asynchronously.
    public func perform(_ block: @escaping @Sendable () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    public var isCurrent: Bool { Thread.current === self }
}
