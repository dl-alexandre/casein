// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "casein-menubar",
    platforms: [.macOS(.v14)],
    targets: [
        // Foundation-only host core: the status contract, health probe, and
        // release lifecycle. No AppKit/SwiftUI so it stays testable and could
        // back a CLI or a different UI shell unchanged.
        .target(name: "CaseinHostCore", path: "Sources/DevIDEHostCore"),
        .executableTarget(
            name: "casein-menubar",
            dependencies: ["CaseinHostCore"],
            path: "Sources/devide-menubar"
        ),
        // Headless harness over the same core the menu buttons call:
        // start/stop/restart/status with timings. Doubles as the CI smoke.
        .executableTarget(
            name: "casein-host-cli",
            dependencies: ["CaseinHostCore"],
            path: "Sources/devide-host-cli"
        ),
        .testTarget(
            name: "CaseinHostCoreTests",
            dependencies: ["CaseinHostCore"],
            path: "Tests/DevIDEHostCoreTests"
        ),
    ]
)
