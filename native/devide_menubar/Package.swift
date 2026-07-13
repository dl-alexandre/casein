// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "devide-menubar",
    platforms: [.macOS(.v14)],
    targets: [
        // Foundation-only host core: the status contract, health probe, and
        // release lifecycle. No AppKit/SwiftUI so it stays testable and could
        // back a CLI or a different UI shell unchanged.
        .target(name: "DevIDEHostCore"),
        .executableTarget(
            name: "devide-menubar",
            dependencies: ["DevIDEHostCore"]
        ),
        // Headless harness over the same core the menu buttons call:
        // start/stop/restart/status with timings. Doubles as the CI smoke.
        .executableTarget(
            name: "devide-host-cli",
            dependencies: ["DevIDEHostCore"]
        ),
        .testTarget(
            name: "DevIDEHostCoreTests",
            dependencies: ["DevIDEHostCore"]
        ),
    ]
)
