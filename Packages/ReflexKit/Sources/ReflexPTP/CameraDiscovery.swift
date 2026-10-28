import Foundation
@preconcurrency import ImageCaptureCore

/// Finds USB PTP cameras via ImageCaptureCore and opens sessions on them.
/// All ImageCaptureCore calls run on one `RunLoopThread`; events are delivered on that thread.
public final class CameraDiscovery: NSObject, @unchecked Sendable {
    public enum Event: Sendable {
        case connected(CameraConnection)
        case disconnected(CameraConnection)
        case failed(String)
    }

    public let thread: RunLoopThread
    private var browser: ICDeviceBrowser?
    private var connections: [ObjectIdentifier: CameraConnection] = [:]
    private let onEvent: @Sendable (Event) -> Void
    /// Optional diagnostics hook (browser lifecycle, session results).
    public var debug: (@Sendable (String) -> Void)?

    public init(thread: RunLoopThread = RunLoopThread(name: "reflex.camera"), onEvent: @escaping @Sendable (Event) -> Void) {
        self.thread = thread
        self.onEvent = onEvent
        super.init()
    }

    public func start() {
        thread.perform { [self] in
            let browser = ICDeviceBrowser()
            browser.delegate = self
            browser.browsedDeviceTypeMask = ICDeviceTypeMask(
                rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
            browser.start()
            self.browser = browser
            self.debug?("Browser started (browsing: \(browser.isBrowsing))")
        }
    }

    public func stop() {
        thread.perform { [self] in
            browser?.stop()
            browser = nil
            for connection in connections.values { connection.close() }
            connections.removeAll()
        }
    }

    public func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        debug?("Browser finished enumerating local devices (\(browser.devices?.count ?? 0))")
    }

    fileprivate func opened(_ connection: CameraConnection) { onEvent(.connected(connection)) }
    fileprivate func failed(_ message: String) { onEvent(.failed(message)) }
}

extension CameraDiscovery: ICDeviceBrowserDelegate {
    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        debug?("Browser found \(device.name ?? "a device") (\(device.transportType ?? "unknown transport"))")
        guard let camera = device as? ICCameraDevice else { return }
        let connection = CameraConnection(camera: camera, thread: thread, discovery: self)
        connections[ObjectIdentifier(camera)] = connection
        connection.open()
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let connection = connections.removeValue(forKey: ObjectIdentifier(device)) else { return }
        connection.close()
        onEvent(.disconnected(connection))
    }
}

/// An open ImageCaptureCore session on one camera, plus its PTP transport.
public final class CameraConnection: NSObject, @unchecked Sendable {
    public let camera: ICCameraDevice
    public let transport: ImageCaptureTransport
    public let name: String
    public let usbVendorID: Int
    public let usbProductID: Int
    public let usbLocationID: UInt32
    private weak var discovery: CameraDiscovery?

    /// PTP events from the interrupt endpoint (raw USB event containers). Set before or after opening.
    public var onPTPEvent: (@Sendable (Data) -> Void)?
    public var onClosed: (@Sendable () -> Void)?

    fileprivate init(camera: ICCameraDevice, thread: RunLoopThread, discovery: CameraDiscovery) {
        self.camera = camera
        self.transport = ImageCaptureTransport(camera: camera, thread: thread)
        self.name = camera.name ?? "Camera"
        self.usbVendorID = Int(camera.usbVendorID)
        self.usbProductID = Int(camera.usbProductID)
        self.usbLocationID = UInt32(bitPattern: camera.usbLocationID)
        self.discovery = discovery
        super.init()
    }

    public var supportsPTPPassthrough: Bool {
        camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
    }

    fileprivate func open() {
        camera.delegate = self
        camera.ptpEventHandler = { [weak self] data in self?.onPTPEvent?(data) }
        camera.requestOpenSession(options: nil) { [weak self] error in
            guard let self else { return }
            if let error {
                self.discovery?.failed("Could not open a session with \(self.name): \(error.localizedDescription)")
            } else {
                self.discovery?.opened(self)
            }
        }
    }

    public func close() {
        transport.close()
        if camera.hasOpenSession { camera.requestCloseSession(options: nil) { _ in } }
        onClosed?()
    }
}

extension CameraConnection: ICCameraDeviceDelegate {
    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) { onPTPEvent?(eventData) }
    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) { transport.close() }
    public func didRemove(_ device: ICDevice) { transport.close() }
    public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
}
