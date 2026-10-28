// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReflexKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReflexPTP", targets: ["ReflexPTP"]),
    ],
    targets: [
        // PTP wire format, Nikon vendor extensions, and the transport protocol.
        // No UI, no Metal: everything here is unit-testable without a camera.
        .target(name: "ReflexPTP"),
        .testTarget(name: "ReflexPTPTests", dependencies: ["ReflexPTP"]),
    ]
)
