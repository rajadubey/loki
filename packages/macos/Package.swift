// swift-tools-version:6.0
import PackageDescription

// Keep in sync with the swiftc flags in scripts/build.sh and scripts/test.sh.
let settings: [SwiftSetting] = [.enableUpcomingFeature("BareSlashRegexLiterals")]

let package = Package(
    name: "Loki",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Loki", targets: ["LokiApp"]),
        .library(name: "LokiCore", targets: ["LokiCore"]),
    ],
    targets: [
        // Engine: machine.json, nginx config, sync, health checks, setup. No UI.
        .target(name: "LokiCore", swiftSettings: settings),
        // Menu bar app. Bundled into Loki.app by scripts/build.sh.
        .executableTarget(name: "LokiApp", dependencies: ["LokiCore"], swiftSettings: settings),
        .testTarget(name: "LokiCoreTests", dependencies: ["LokiCore"], swiftSettings: settings),
    ],
    swiftLanguageModes: [.v5]
)
