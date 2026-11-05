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
        .testTarget(name: "CoreLiveTests", dependencies: ["CoreLive", "CoreAPI", "CoreFake"]),
    ]
)
