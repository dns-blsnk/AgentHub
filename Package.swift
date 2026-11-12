// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentHub",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "AgentHubCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AgentHub",
            dependencies: ["AgentHubCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentHubCoreTests",
            dependencies: ["AgentHubCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
