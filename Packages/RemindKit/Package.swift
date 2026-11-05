// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RemindKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoreAPI", targets: ["CoreAPI"]),
        .library(name: "CoreLive", targets: ["CoreLive"]),
        .library(name: "CoreFake", targets: ["CoreFake"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "Ingest", targets: ["Ingest"]),
        .library(name: "FrameEngine", targets: ["FrameEngine"]),
    ],
    targets: [
        // Built by scripts/build-core.sh.
        .binaryTarget(name: "RemindCoreFFI", path: "Frameworks/RemindCoreFFI.xcframework"),
        .target(
            name: "CoreABI",
            dependencies: ["RemindCoreFFI"],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "CoreAPI"),
        .target(name: "CoreLive", dependencies: ["CoreABI", "CoreAPI"]),
        .target(name: "CoreFake", dependencies: ["CoreAPI"]),
        .target(name: "DesignSystem"),
        .target(name: "Capture"),
        .target(name: "Ingest", dependencies: ["CoreAPI", "Capture", "FrameEngine"]),
        .target(name: "FrameEngine", dependencies: ["CoreAPI"]),
        .target(name: "TestKit", dependencies: ["CoreAPI"]),
        // Measurements that don't need any permissions.
        .executableTarget(
            name: "remind-spike",
            dependencies: ["CoreAPI", "CoreLive", "Ingest", "FrameEngine", "TestKit"]
        ),
        .testTarget(name: "CoreLiveTests", dependencies: ["CoreLive", "CoreAPI", "CoreFake"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture"]),
        .testTarget(name: "IngestTests", dependencies: ["Ingest", "Capture", "FrameEngine", "TestKit", "CoreAPI", "CoreLive", "CoreFake"]),
    ]
)
