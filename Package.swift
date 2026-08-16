// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CodexDashboard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexMetricsCore", targets: ["CodexMetricsCore"]),
        .executable(name: "codex-metrics", targets: ["CodexMetricsCLI"]),
        .executable(name: "CodexDashboard", targets: ["CodexDashboard"])
    ],
    targets: [
        .target(
            name: "CodexMetricsCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CodexMetricsCLI",
            dependencies: ["CodexMetricsCore"]
        ),
        .executableTarget(
            name: "CodexDashboard",
            dependencies: ["CodexMetricsCore"]
        ),
        .testTarget(
            name: "CodexMetricsCoreTests",
            dependencies: ["CodexMetricsCore"]
        )
    ]
)
