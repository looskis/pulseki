// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pulseki",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "pulseki", targets: ["pulseki"]),
    ],
    targets: [
        // Small C layer for the two places where exact struct layout matters:
        // the AppleSMC user-client protocol and the NET_RT_IFLIST2 routing socket dump.
        .target(name: "CSystem", path: "Sources/CSystem"),
        .target(
            name: "PulsekiCore",
            dependencies: ["CSystem"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedLibrary("z")]
        ),
        .executableTarget(name: "pulseki", dependencies: ["PulsekiCore"]),
        .testTarget(name: "PulsekiCoreTests", dependencies: ["PulsekiCore"]),
    ]
)
