// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReflexKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReflexPTP", targets: ["ReflexPTP"]),
        .library(name: "ReflexCamera", targets: ["ReflexCamera"]),
        .library(name: "ReflexVideo", targets: ["ReflexVideo"]),
    ],
    targets: [
        // PTP wire format, Nikon vendor extensions, and the transport protocol.
        // No UI, no Metal: everything here is unit-testable without a camera.
        .target(name: "ReflexPTP"),
        // A connected Nikon body: live-view configuration and loop, status, restore-on-exit.
        .target(name: "ReflexCamera", dependencies: ["ReflexPTP"]),
        // VideoToolbox decode, Metal convert/crop, viewfinder, frame sinks.
        .target(name: "ReflexVideo", dependencies: ["ReflexPTP"]),
        .testTarget(name: "ReflexPTPTests", dependencies: ["ReflexPTP"]),
        .testTarget(name: "ReflexCameraTests", dependencies: ["ReflexCamera"]),
        .testTarget(name: "ReflexVideoTests", dependencies: ["ReflexVideo"]),
    ]
)
