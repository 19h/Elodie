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
        .library(name: "TestKit", targets: ["TestKit"]),
        .library(name: "StripRenderer", targets: ["StripRenderer"]),
        .library(name: "OverlayShell", targets: ["OverlayShell"]),
        .library(name: "FeatureTimeline", targets: ["FeatureTimeline"]),
        .library(name: "FeatureSearch", targets: ["FeatureSearch"]),
        .library(name: "FeatureOnboarding", targets: ["FeatureOnboarding"]),
        .library(name: "FeatureSettings", targets: ["FeatureSettings"]),
        .library(name: "FeatureAsk", targets: ["FeatureAsk"]),
        .library(name: "Audio", targets: ["Audio"]),
        .library(name: "FeatureMeetings", targets: ["FeatureMeetings"]),
        .library(name: "FeatureRecap", targets: ["FeatureRecap"]),
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
        .target(name: "StripRenderer"),
        .target(name: "OverlayShell", dependencies: ["StripRenderer"]),
        .target(name: "FeatureSearch", dependencies: ["CoreAPI", "DesignSystem"]),
        .target(name: "FeatureOnboarding", dependencies: ["DesignSystem"]),
        .target(name: "FeatureSettings", dependencies: ["DesignSystem"]),
        .target(name: "FeatureAsk", dependencies: ["CoreAPI", "DesignSystem"]),
        .target(name: "Audio", dependencies: ["CoreAPI", "Capture"]),
        .target(name: "FeatureMeetings", dependencies: ["CoreAPI", "DesignSystem", "Audio", "FeatureAsk"]),
        .target(name: "FeatureRecap", dependencies: ["CoreAPI", "DesignSystem", "FeatureAsk"]),
        .target(name: "FeatureTimeline", dependencies: ["CoreAPI", "DesignSystem", "FrameEngine", "OverlayShell", "StripRenderer"]),
        .target(name: "TestKit", dependencies: ["CoreAPI", "Ingest"]),
        // Measurements that don't need any permissions.
        .executableTarget(
            name: "remind-spike",
            dependencies: ["CoreAPI", "CoreLive", "Ingest", "FrameEngine", "TestKit"]
        ),
        .testTarget(name: "CoreLiveTests", dependencies: ["CoreLive", "CoreAPI", "CoreFake"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture"]),
        .testTarget(name: "AskTests", dependencies: ["FeatureAsk", "CoreAPI", "CoreFake"]),
        .testTarget(name: "AudioTests", dependencies: ["Audio", "Capture", "CoreAPI", "CoreLive", "CoreFake"]),
        .testTarget(name: "InterfaceTests", dependencies: ["DesignSystem", "StripRenderer", "OverlayShell", "FeatureTimeline", "FeatureSearch", "FeatureOnboarding", "FeatureSettings", "CoreAPI", "CoreFake"]),
        .testTarget(name: "FrameEngineTests", dependencies: ["FrameEngine", "CoreAPI", "CoreLive", "CoreFake", "TestKit"]),
        .testTarget(name: "IngestTests", dependencies: ["Ingest", "Capture", "FrameEngine", "TestKit", "CoreAPI", "CoreLive", "CoreFake"]),
    ]
)
