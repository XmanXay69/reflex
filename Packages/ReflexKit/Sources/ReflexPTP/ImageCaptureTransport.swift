@preconcurrency import Foundation
@preconcurrency import ImageCaptureCore

/// PTP over Apple's ImageCaptureCore passthrough (`ICCameraDevice.requestSendPTPCommand`).
///
/// Why this instead of libusb/libgphoto2: macOS's `ptpcamerad` claims every PTP camera the moment it
/// is plugged in, so a libusb client has to keep killing that daemon. Going through ImageCaptureCore
/// shares the daemon's session instead: no USB entitlements, no daemon fights, no signing requirements.
public final class ImageCaptureTransport: NSObject, PTPTransport, @unchecked Sendable {
    public let camera: ICCameraDevice
    private let thread: RunLoopThread
    private let timeout: Double

    private let lock = NSLock()
    private var nextTransactionID: UInt32 = 1
    private var queue: [Request] = []
    private var inFlight = false
    private var isClosed = false

    private final class Request: @unchecked Sendable {
        let code: PTPOperationCode
        let params: [UInt32]
        let dataOut: Data?
        let timeout: Double?
        private var continuation: CheckedContinuation<PTPTransaction, Error>?
        private let lock = NSLock()

        init(code: PTPOperationCode, params: [UInt32], dataOut: Data?, timeout: Double?,
             continuation: CheckedContinuation<PTPTransaction, Error>) {
            self.code = code
            self.params = params
            self.dataOut = dataOut
            self.timeout = timeout
            self.continuation = continuation
        }

        /// Resumes at most once (a late ImageCaptureCore callback after a timeout is dropped).
        @discardableResult
        func resume(_ result: Result<PTPTransaction, Error>) -> Bool {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
            return c != nil
        }
    }

    public init(camera: ICCameraDevice, thread: RunLoopThread, timeout: Double = 5) {
        self.camera = camera
        self.thread = thread
        self.timeout = timeout
    }

    public func transact(_ code: PTPOperationCode, params: [UInt32], dataOut: Data?, timeout: Double?) async throws -> PTPTransaction {
        try await withCheckedThrowingContinuation { continuation in
            let request = Request(code: code, params: params, dataOut: dataOut, timeout: timeout, continuation: continuation)
            lock.lock()
            if isClosed {
                lock.unlock()
                request.resume(.failure(PTPError.disconnected))
                return
            }
            queue.append(request)
            lock.unlock()
            pump()
        }
    }

    /// Fails everything queued; later calls throw `.disconnected`.
    public func close() {
        lock.lock()
        isClosed = true
        let pending = queue
        queue.removeAll()
        lock.unlock()
        for request in pending { request.resume(.failure(PTPError.disconnected)) }
    }

    private func pump() {
        lock.lock()
        guard !inFlight, !queue.isEmpty else { lock.unlock(); return }
        inFlight = true
        let request = queue.removeFirst()
        let tid = nextTransactionID
        nextTransactionID &+= 1
        lock.unlock()

        thread.perform { [self] in
            let command = PTPCommand(request.code, transactionID: tid, params: request.params).encoded()
            let sentAt = hostTime()
            let timer = DispatchWorkItem { [weak self] in
                if request.resume(.failure(PTPError.timedOut(request.code))) { self?.didFinish() }
            }
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + (request.timeout ?? timeout), execute: timer)

            camera.requestSendPTPCommand(command, outData: request.dataOut) { [weak self] data, response, error in
                let completedAt = hostTime()
                timer.cancel()
                let result: Result<PTPTransaction, Error>
                if let error {
                    result = .failure(PTPError.transport((error as NSError).description))
                } else {
                    do {
                        let decoded = try PTPResponse.decode(response)
                        result = .success(PTPTransaction(response: decoded, data: ptpPayload(fromDataPhase: data),
                                                         sentAt: sentAt, completedAt: completedAt))
                    } catch {
                        result = .failure(error)
                    }
                }
                if request.resume(result) { self?.didFinish() }
            }
        }
    }

    private func didFinish() {
        lock.lock()
        inFlight = false
        lock.unlock()
        pump()
    }
}
