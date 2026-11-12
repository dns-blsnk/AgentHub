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
        // Logic of the app target that needs no agents, Keychain or windows: alerts, summaries, formatting.
        .testTarget(
            name: "AgentHubTests",
            dependencies: ["AgentHub"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentHubCoreTests",
            dependencies: ["AgentHubCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
