import Foundation
import IOKit

/// Negotiated USB link speed of a device, read from the IORegistry by USB location ID.
/// Used to warn when a USB 3 camera is held back by a USB 2-only cable.
public struct USBLinkSpeed: Sendable, Equatable {
    public var bitsPerSecond: Int

    public var isUSB2OrSlower: Bool { bitsPerSecond <= 480_000_000 }

    public var label: String {
        switch bitsPerSecond {
        case ..<12_000_001: "USB 1.1"
        case ..<480_000_001: "USB 2.0"
        case ..<5_000_000_001: "USB 5 Gb/s"
        case ..<10_000_000_001: "USB 10 Gb/s"
        default: "USB \(bitsPerSecond / 1_000_000_000) Gb/s"
        }
    }

    public static func lookup(locationID: UInt32) -> USBLinkSpeed? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let location = property(service, "locationID") as? NSNumber, location.uint32Value == locationID else { continue }
            if let speed = property(service, "UsbLinkSpeed") as? NSNumber { return USBLinkSpeed(bitsPerSecond: speed.intValue) }
        }
        return nil
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
